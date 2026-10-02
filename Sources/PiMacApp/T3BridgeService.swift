import AppKit
import Combine
import Foundation

/// Supervises the loopback T3 Server; phones connect only through managed Tunnel.
@MainActor
final class T3BridgeService: ObservableObject {
  @Published private(set) var port: Int?
  @Published private(set) var status = "未启用"
  @Published private(set) var isStopping = false
  private let defaults: UserDefaults
  private let stateDirectory: URL?
  private var stoppingPID: Int32?
  @Published private(set) var serverURL: URL?
  @Published private(set) var clients: [T3PairedClient] = []
  @Published private(set) var managementBusy = false
  private var clientRefreshID: UUID?
  @Published private(set) var managementMessage = ""
  @Published private(set) var connectStatus: T3ConnectStatus?
  @Published private(set) var connectBusy = false
  @Published private(set) var connectMessage = ""
  private var adminToken = ""
  private let adminSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 5
    return URLSession(configuration: configuration)
  }()

  init(defaults: UserDefaults = .standard, stateDirectory: URL? = nil) {
    self.defaults = defaults
    self.stateDirectory = stateDirectory
    // Migrate away from LAN-only consent; never reopen a saved listener.
    T3ConnectionPreferences.save(nil, to: defaults)
  }

  private var process: Process?
  private var input: FileHandle?
  private var generation = UUID()
  private var writer = DispatchQueue(label: "pimac.t3.bridge.writer")

  func start(
    workspace: WorkspaceModel, token: String, stateDirectory: URL? = nil
  ) throws {
    guard process?.isRunning != true else { return }
    guard token.count == 64, token.allSatisfy({ "0123456789abcdef".contains($0) }) else {
      throw ServiceError.invalidToken
    }
    guard let resource = Bundle.module.url(forResource: "t3-bridge", withExtension: nil) else {
      throw ServiceError.missingResource
    }
    let child = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    let current = UUID()
    generation = current
    writer = DispatchQueue(label: "pimac.t3.bridge.writer.\(current)")
    child.executableURL = URL(fileURLWithPath: "/bin/zsh")
    child.arguments = [
      "-lc", "exec node \"$1\"", "pimac-t3",
      resource.appendingPathComponent("server-gateway.mjs").path,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["PIMAC_T3_BRIDGE_TOKEN"] = token
    environment["PIMAC_PI_BINARY"] = defaults.string(forKey: "piPath") ?? AppModel.suggestedPiPath()
    // Do not inherit network exposure from a launching shell.
    environment.removeValue(forKey: "PIMAC_T3_PUBLIC_HOST")
    environment.removeValue(forKey: "PIMAC_T3_PUBLIC_PORT")
    let stateDirectory =
      stateDirectory
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("PiMac/T3", isDirectory: true)
    let lease = try T3BridgeStateLease(directory: stateDirectory)
    environment["PIMAC_T3_AUTH_FILE"] = stateDirectory.appendingPathComponent("auth.json").path
    child.environment = environment
    child.standardInput = stdin
    child.standardOutput = stdout
    child.standardError = stderr
    child.terminationHandler = { [weak self, lease] child in
      lease.release()
      Task { @MainActor [weak self] in
        guard let self else { return }
        if self.stoppingPID == child.processIdentifier {
          self.stoppingPID = nil
          self.isStopping = false
        }
        guard self.generation == current else { return }
        self.stop()
        self.status = "连接服务已退出（\(child.terminationStatus)）"
      }
    }
    do {
      try child.run()
      process = child
      input = stdin.fileHandleForWriting
      adminToken = token
      status = "本机 T3 Server 启动中"
      // Read supervisor readiness only, after process/input/generation are ready.
      T3BridgePipeReader.start(stdout.fileHandleForReading) { [weak self] record in
        Task { @MainActor [weak self] in self?.receive(record, generation: current) }
      }
      // Drain, but never log stderr: it may contain credentials or prompt text.
      T3BridgePipeReader.start(stderr.fileHandleForReading)
    } catch {
      lease.release()
      throw error
    }
  }

  func stop() {
    generation = UUID()
    adminToken = ""
    serverURL = nil
    clients = []
    connectStatus = nil
    connectBusy = false
    connectMessage = ""
    clientRefreshID = nil
    managementBusy = false
    managementMessage = ""
    port = nil
    let oldInput = input
    input = nil
    writer.async { try? oldInput?.close() }
    let old = process
    process = nil
    if let old, old.isRunning {
      isStopping = true
      stoppingPID = old.processIdentifier
      old.terminate()
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        if old.isRunning { kill(old.processIdentifier, SIGKILL) }
      }
    }
    status = "未启用"
  }

  private func receive(_ record: Data, generation current: UUID) {
    guard generation == current, process?.isRunning == true else { return }
    if let message = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
      message["type"] as? String == "startup_error"
    {
      stop()
      status =
        message["code"] as? String == "address_in_use"
        ? "端口已被占用，请更换端口后重试。" : "本机 T3 Server 启动失败，请检查 Node、资源及服务锁。"
      return
    }
    if let message = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
      message["type"] as? String == "ready", let port = message["port"] as? Int,
      (1...65535).contains(port)
    {
      self.port = port
      if let serverPort = message["serverPort"] as? Int, (1...65535).contains(serverPort) {
        serverURL = URL(string: "http://127.0.0.1:\(serverPort)")
      }
      status = "本机 T3 Server 已启动（桌面统一使用 Server）"
      return
    }
    // No desktop/Pi requests on stdio. This pipe carries supervisor readiness only.
  }

  private func admin<T: Decodable>(
    _ path: String, method: String = "GET",
    body: [String: String]? = nil
  ) async throws -> T {
    guard let port, !adminToken.isEmpty else { throw ServiceError.notRunning }
    let current = generation
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/internal/auth/\(path)")!)
    request.httpMethod = method
    if path == "connect" { request.timeoutInterval = 45 }
    request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
    let (data, response) = try await adminSession.data(for: request)
    guard generation == current, process?.isRunning == true else { throw CancellationError() }
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 256 * 1024 else {
      throw ServiceError.managementFailed
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  func desktopCredential() async throws -> String {
    struct Credential: Decodable { let token: String }
    let result: Credential = try await admin("desktop-session", method: "POST", body: [:])
    return result.token
  }

  func sessionMetrics(threadID: String) async throws -> SessionStats? {
    struct Metrics: Decodable {
      struct Tokens: Decodable { let input: Int?; let cacheRead: Int?; let cacheWrite: Int?; let total: Int? }
      struct Context: Decodable { let percent: Double? }
      let cost: Double?
      let outputTokensPerSecond: Double?
      let tokens: Tokens
      let contextUsage: Context?
    }
    struct Response: Decodable { let stats: Metrics? }
    let response: Response = try await admin(
      "session-metrics", method: "POST", body: ["threadId": threadID])
    guard let stats = response.stats else { return nil }
    return SessionStats(
      cost: stats.cost ?? 0, contextPercent: stats.contextUsage?.percent,
      totalTokens: stats.tokens.total ?? 0, inputTokens: stats.tokens.input ?? 0,
      cacheReadTokens: stats.tokens.cacheRead ?? 0, cacheWriteTokens: stats.tokens.cacheWrite ?? 0,
      outputTokensPerSecond: stats.outputTokensPerSecond)
  }

  func accountStatus(threadID: String, provider: String? = nil) async throws -> [String: Any]? {
    struct Snapshot: Decodable { let status: String? }
    var body = ["threadId": threadID]
    if let provider { body["provider"] = provider }
    let snapshot: Snapshot = try await admin(
      "account-status", method: "POST", body: body)
    guard let value = snapshot.status,
      let data = value.data(using: .utf8)
    else { return nil }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  func connectAction(_ operation: String) async {
    guard !connectBusy, port != nil,
      [
        "login", "reauthorize", "cancel-login", "retry-link", "refresh-devices", "enable",
        "disable", "logout",
      ].contains(operation)
    else { return }
    let current = generation
    connectBusy = true
    connectMessage = ""
    defer { if generation == current { connectBusy = false } }
    do {
      if operation == "login" || operation == "reauthorize" {
        struct Login: Decodable { let url: String? }
        let login: Login = try await admin(
          "connect", method: "POST", body: ["operation": operation])
        if let authorizationURL = login.url {
          guard let url = URL(string: authorizationURL), url.scheme == "https",
            url.host == "app.t3.codes", url.path == "/connect", url.user == nil,
            url.password == nil,
            NSWorkspace.shared.open(url)
          else {
            let _: T3ConnectStatus? = try? await admin(
              "connect", method: "POST", body: ["operation": "cancel-login"])
            throw ServiceError.managementFailed
          }
        }
      } else {
        let result: T3ConnectStatus = try await admin(
          "connect", method: "POST", body: ["operation": operation])
        guard generation == current else { return }
        connectStatus = result
      }
    } catch {
      if generation == current {
        connectMessage = "操作未确认成功；请刷新状态后重试。无法打开网页时，请检查默认浏览器及本机 34338 端口是否被占用。"
      }
    }
    guard generation == current else { return }
    let result: T3ConnectStatus? = try? await admin("connect")
    guard generation == current else { return }
    connectStatus = result
  }

  private struct Revocation: Decodable { let revoked: Bool }

  func refreshClients() async {
    guard !managementBusy, clientRefreshID == nil, port != nil else { return }
    let current = generation
    let refreshID = UUID()
    clientRefreshID = refreshID
    defer { if clientRefreshID == refreshID { clientRefreshID = nil } }
    do {
      let values: [T3PairedClient] = try await admin("clients")
      guard generation == current else { return }
      if clients != values { clients = values }
      if !connectBusy {
        let value: T3ConnectStatus? = try? await admin("connect")
        guard generation == current else { return }
        if connectStatus != value { connectStatus = value }
      }
    } catch {
      if generation == current { managementMessage = "无法刷新设备列表。" }
    }
  }

  func revokeClient(_ id: String) async {
    guard !managementBusy else { return }
    let current = generation
    managementBusy = true
    defer { if generation == current { managementBusy = false } }
    do {
      let _: Revocation = try await admin("revoke-client", method: "POST", body: ["sessionId": id])
      let values: [T3PairedClient] = try await admin("clients")
      clients = values
      managementMessage = "设备授权已撤销。"
    } catch {
      if generation == current { managementMessage = "撤销失败；不能视为设备已断开。" }
    }
  }

  enum ServiceError: Error {
    case invalidToken
    case missingResource
    case invalidEndpoint
    case randomUnavailable
    case notRunning
    case managementFailed
  }
}

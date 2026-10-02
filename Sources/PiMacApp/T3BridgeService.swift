import AppKit
import Combine
import Foundation

/// Supervises one local T3 Server. LAN exposure is independent of its lifetime.
@MainActor
final class T3BridgeService: ObservableObject {
  @Published private(set) var port: Int?
  @Published private(set) var status = "未启用"
  @Published private(set) var isEnabled = false
  @Published private(set) var isStopping = false
  @Published private(set) var rememberedNetwork: T3NetworkEndpoint?
  private let defaults: UserDefaults
  private let stateDirectory: URL?
  private var stoppingPID: Int32?
  @Published private(set) var publicURL: URL?
  @Published private(set) var serverURL: URL?
  @Published private(set) var pairing: T3Pairing?
  @Published private(set) var clients: [T3PairedClient] = []
  @Published private(set) var managementBusy = false
  private var clientRefreshID: UUID?
  @Published private(set) var managementMessage = ""
  @Published private(set) var connectStatus: T3ConnectStatus?
  @Published private(set) var connectBusy = false
  @Published private(set) var connectMessage = ""
  private var pairingGeneration = UUID()
  private var adminToken = ""
  private var requestedNetwork: T3NetworkEndpoint?
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
    rememberedNetwork = T3ConnectionPreferences.load(from: defaults)
  }

  /// Only user actions clear consent. Process shutdown/failure preserves it.
  func forgetNetworkPreference() {
    rememberedNetwork = nil
    T3ConnectionPreferences.save(nil, to: defaults)
  }

  func disable() {
    forgetNetworkPreference()
    Task { await setNetwork(nil) }
  }

  @discardableResult
  func restoreRememberedConnection(workspace: WorkspaceModel) -> Bool {
    guard let network = rememberedNetwork else { return false }
    enable(workspace: workspace, network: network)
    return true
  }

  var connectionURL: URL? {
    publicURL ?? serverURL ?? port.flatMap { URL(string: "http://127.0.0.1:\($0)") }
  }

  func enable(workspace: WorkspaceModel, network: T3NetworkEndpoint?) {
    // Called after explicit consent (or restoration of that same consent).
    // Retain the preference even if Node/listen fails; never pick another IP.
    rememberedNetwork = network
    T3ConnectionPreferences.save(network, to: defaults)
    do {
      if process?.isRunning != true {
        try start(
          workspace: workspace, token: T3NetworkEndpoint.secret(), stateDirectory: stateDirectory,
          network: network)
        return  // The readiness record applies the requested LAN endpoint once.
      }
      Task {
        for _ in 0..<600 {
          if port != nil { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
        await setNetwork(network)
      }
    } catch {
      status = "本机 T3 Server 无法启动：请检查 Node、资源及服务锁。"
    }
  }
  private var process: Process?
  private var input: FileHandle?
  private var generation = UUID()
  private var writer = DispatchQueue(label: "pimac.t3.bridge.writer")

  func start(
    workspace: WorkspaceModel, token: String, stateDirectory: URL? = nil,
    network: T3NetworkEndpoint? = nil
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
    if let network {
      environment["PIMAC_T3_PUBLIC_HOST"] = network.host
      environment["PIMAC_T3_PUBLIC_PORT"] = String(network.port)
    }
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
      requestedNetwork = network
      isEnabled = false
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
    isEnabled = false
    adminToken = ""
    requestedNetwork = nil
    publicURL = nil
    serverURL = nil
    pairingGeneration = UUID()
    pairing = nil
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
      if let network = requestedNetwork ?? rememberedNetwork { Task { await setNetwork(network) } }
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

  private func setNetwork(_ network: T3NetworkEndpoint?) async {
    struct Network: Decodable { let publicURL: String? }
    let current = generation
    do {
      let result: Network = try await admin(
        "network", method: "POST",
        body: network.map { ["host": $0.host, "port": String($0.port)] } ?? [:])
      guard generation == current else { return }
      publicURL = result.publicURL.flatMap(URL.init(string:))
      isEnabled = publicURL != nil
      status = isEnabled ? "局域网访问已开启；桌面与手机共用 T3 Server" : "仅局域网访问已关闭；本机 Server 继续运行"
    } catch {
      guard generation == current else { return }
      isEnabled = false
      publicURL = nil
      status = "局域网监听失败，请检查 IP/端口；本机 Server 不受影响。"
    }
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

  func generatePairing(label: String) async {
    guard !managementBusy, port != nil else { return }
    let current = generation
    let pairingRequest = UUID()
    pairingGeneration = pairingRequest
    managementBusy = true
    managementMessage = ""
    defer { if generation == current { managementBusy = false } }
    do {
      if let old = pairing {
        pairing = nil
        let _: Revocation = try await admin("revoke-pairing", method: "POST", body: ["id": old.id])
      }
      let grant: T3Pairing = try await admin("pairing", method: "POST", body: ["label": label])
      guard (12...128).contains(grant.credential.count),
        grant.credential.allSatisfy({
          "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_".contains($0)
        }),
        let expiry = grant.expiry, expiry > .now
      else { throw ServiceError.managementFailed }
      if pairingGeneration == pairingRequest {
        pairing = grant
      } else {
        let _: Revocation = try await admin(
          "revoke-pairing", method: "POST", body: ["id": grant.id])
      }
    } catch {
      if generation == current { managementMessage = "无法生成配对码，请检查连接服务。" }
    }
  }

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
      if let pairing {
        struct Link: Decodable { let id: String }
        let links: [Link] = try await admin("pairing-links")
        guard generation == current else { return }
        if self.pairing?.id == pairing.id, !links.contains(where: { $0.id == pairing.id }) {
          self.pairing = nil
        }
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

  func discardPairing() async {
    pairingGeneration = UUID()
    guard let old = pairing else { return }
    pairing = nil
    let current = generation
    do {
      let _: Revocation = try await admin("revoke-pairing", method: "POST", body: ["id": old.id])
    } catch {
      if generation == current { managementMessage = "配对链接撤销失败；原链接将在到期后失效。" }
    }
  }

  func expirePairing() {
    if let pairing, (pairing.expiry ?? .distantPast) <= .now { self.pairing = nil }
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

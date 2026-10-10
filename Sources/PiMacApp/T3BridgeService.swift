import AppKit
import Combine
import Foundation

/// Supervises the loopback T3 Server and a default-on, authenticated LAN transport.
@MainActor
final class T3BridgeService: ObservableObject {
  @Published private(set) var port: Int?
  @Published private(set) var status = "未启用"
  @Published private(set) var isStopping = false
  private let defaults: UserDefaults
  private let stateDirectory: URL?
  private let startupTimeout: Duration
  private var startupWatchdog: Task<Void, Never>?
  private var stoppingPID: Int32?
  private var stoppingProcess: Process?
  @Published private(set) var serverURL: URL?
  @Published private(set) var lanEndpoint: T3NetworkEndpoint?
  @Published private(set) var lanBusy = false
  @Published private(set) var lanMessage = ""
  @Published private(set) var lanPairing: T3Pairing?
  @Published private(set) var lanStateKnown = true
  var lanURL: URL? {
    lanEndpoint?.connectionURL()
  }
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

  init(
    defaults: UserDefaults = .standard, stateDirectory: URL? = nil,
    startupTimeout: Duration = .seconds(60)
  ) {
    self.defaults = defaults
    self.stateDirectory = stateDirectory
    self.startupTimeout = startupTimeout
    // Legacy endpoint data is not reused; current LAN policy owns address selection.
    defaults.removeObject(forKey: "t3RememberedNetworkEndpoint")
  }

  private var process: Process?
  private var childLockFile: URL?
  private var input: FileHandle?
  private var generation = UUID()
  private var writer = DispatchQueue(label: "pimac.t3.bridge.writer")

  func start(
    workspace: WorkspaceModel, token: String, stateDirectory: URL? = nil
  ) throws {
    guard !isStopping else { throw T3BridgeStateLease.LeaseError.alreadyOwned }
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
    environment["PIMAC_T3_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
    environment["PIMAC_PI_BINARY"] = defaults.string(forKey: "piPath") ?? AppModel.suggestedPiPath()
    // Do not inherit network exposure from a launching shell.
    environment.removeValue(forKey: "PIMAC_T3_PUBLIC_HOST")
    environment.removeValue(forKey: "PIMAC_T3_PUBLIC_PORT")
    let stateDirectory =
      stateDirectory
      ?? self.stateDirectory
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
          self.stoppingProcess = nil
          self.isStopping = false
        }
        guard self.generation == current else { return }
        self.stop()
        self.status = "连接服务已退出（\(child.terminationStatus)）"
      }
    }
    do {
      try child.run()
      childLockFile = stateDirectory.appendingPathComponent("child-owner.lock")
      process = child
      input = stdin.fileHandleForWriting
      adminToken = token
      status = "本机 T3 Server 启动中"
      startupWatchdog?.cancel()
      startupWatchdog = Task { [weak self, startupTimeout] in
        do { try await Task.sleep(for: startupTimeout) } catch { return }
        guard let self, self.generation == current, self.serverURL == nil else { return }
        self.stop()
        self.status = "本机 T3 Server 启动超时，请检查 Node 与服务资源后重试。"
      }
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

  /// Call before disconnectAll(), which already sends EOF to the Server.
  func prepareForUpdateRestart() throws {
    guard process?.isRunning == true, let childLockFile else { return }
    try T3UpdateRestart.prepare(in: childLockFile.deletingLastPathComponent())
  }

  func stop() {
    startupWatchdog?.cancel()
    startupWatchdog = nil
    generation = UUID()
    adminToken = ""
    serverURL = nil
    lanEndpoint = nil
    lanPairing = nil
    lanBusy = false
    lanMessage = ""
    lanStateKnown = true
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
      stoppingProcess = old
      // EOF is the normal shutdown request. Give upstream finalizers time to
      // stop Pi and Tunnel before escalating (SIGTERM uses the same finalizers).
      DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
        if old.isRunning { old.terminate() }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
        if old.isRunning { kill(old.processIdentifier, SIGKILL) }
      }
    }
    status = "未启用"
  }

  /// Wait for both the process termination handler and the kernel child lease.
  /// A diagnostic PID file left by SIGKILL is never a shutdown barrier.
  func stopAndWait() async -> Bool {
    stop()
    NSLog("Pi Mac T3 shutdown barrier: waiting for process and child lease")
    for _ in 0..<360 {
      // The termination callback may be queued after the process is already gone.
      // Do not keep the UI in "stopping" solely because that callback is late.
      if let old = stoppingProcess,
        !old.isRunning || (kill(old.processIdentifier, 0) == -1 && errno == ESRCH)
      {
        stoppingPID = nil
        stoppingProcess = nil
        isStopping = false
      }
      if !isStopping && childLeaseHasCleared {
        NSLog("Pi Mac T3 shutdown barrier: cleared")
        return true
      }
      if Task.isCancelled {
        NSLog("Pi Mac T3 shutdown barrier: cancelled")
        return false
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    let cleared = !isStopping && childLeaseHasCleared
    NSLog(
      "Pi Mac T3 shutdown barrier: cleared=%d, stopping=%d, childLeaseAvailable=%d",
      cleared, isStopping, childLeaseHasCleared)
    return cleared
  }

  private var childLeaseHasCleared: Bool {
    guard let childLockFile else { return true }
    return T3BridgeStateLease.isAvailable(childLockFile)
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
      (1...65535).contains(port), let serverPort = message["serverPort"] as? Int,
      (1...65535).contains(serverPort)
    {
      startupWatchdog?.cancel()
      startupWatchdog = nil
      self.port = port
      serverURL = URL(string: "http://127.0.0.1:\(serverPort)")
      status = "本机 T3 Server 已启动（桌面统一使用 Server）"
      if let endpoint = T3ConnectionPreferences.startupEndpoint(from: defaults) {
        Task { [weak self] in
          guard let self, self.generation == current else { return }
          await self.configureLAN(endpoint)
        }
      }
      return
    }
    // No desktop/Pi requests on stdio. This pipe carries supervisor readiness only.
  }

  private func admin<T: Decodable>(
    _ path: String, method: String = "GET",
    body: [String: Any]? = nil
  ) async throws -> T {
    guard let port, !adminToken.isEmpty else { throw ServiceError.notRunning }
    let current = generation
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/internal/auth/\(path)")!)
    request.httpMethod = method
    if path == "connect" { request.timeoutInterval = 45 }
    if path == "account-status" { request.timeoutInterval = 20 }
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

  func modelCatalog() async throws -> [String: [[String: Any]]] {
    struct Response: Decodable { let catalogs: String }
    let response: Response = try await admin("model-catalog")
    let data = Data(response.catalogs.utf8)
    return try JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] ?? [:]
  }

  func syncModelPreferences(hiddenModels: [String], defaultModel: String?) async throws {
    struct Response: Decodable { let ok: Bool }
    let _: Response = try await admin(
      "model-preferences", method: "POST",
      body: [
        "hiddenModels": hiddenModels, "defaultModel": defaultModel as Any? ?? NSNull(),
      ])
  }

  func accountStatus(provider: String, force: Bool) async throws -> [String: Any] {
    struct Response: Decodable { let payload: String }
    let response: Response = try await admin(
      "account-status", method: "POST", body: ["provider": provider, "force": force])
    return try JSONSerialization.jsonObject(with: Data(response.payload.utf8)) as? [String: Any]
      ?? [:]
  }

  func desktopCredential() async throws -> String {
    struct Credential: Decodable { let token: String }
    let result: Credential = try await admin("desktop-session", method: "POST", body: [:])
    return result.token
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

  private struct LANStatus: Decodable {
    struct Endpoint: Decodable {
      let host: String
      let port: Int
    }
    let endpoint: Endpoint?
  }

  func configureLAN(_ endpoint: T3NetworkEndpoint?) async {
    guard !lanBusy, lanStateKnown, port != nil else { return }
    // Persist requested on/off policy even if acknowledgement is lost. Actual
    // live exposure is still reconciled separately and never assumed closed.
    defaults.set(endpoint != nil, forKey: T3ConnectionPreferences.enabledKey)
    let current = generation
    lanBusy = true
    lanPairing = nil
    lanMessage = ""
    defer { if generation == current { lanBusy = false } }
    do {
      let value: Any = endpoint.map { ["host": "0.0.0.0", "port": $0.port] as Any } ?? NSNull()
      let result: LANStatus = try await admin("lan", method: "POST", body: ["endpoint": value])
      guard generation == current else { return }
      try applyLANStatus(result)
      lanMessage = lanEndpoint == nil ? "局域网直连已关闭。" : "局域网直连已开启；手机需在同一网络并单独配对。"
    } catch {
      guard generation == current else { return }
      // A lost acknowledgement does not mean the listener stayed unchanged.
      lanStateKnown = false
      if await reconcileLAN(generation: current) {
        lanMessage = "操作未确认成功，已读取实际状态；请检查端口后重试。"
      } else if generation == current {
        lanMessage = "无法确认局域网入口状态，可能仍在监听。请刷新状态；不要视为已经关闭。"
      }
    }
  }

  private func applyLANStatus(_ result: LANStatus) throws {
    let endpoint = try result.endpoint.map { try T3NetworkEndpoint(host: $0.host, port: $0.port) }
    if endpoint != lanEndpoint { lanPairing = nil }
    lanEndpoint = endpoint
    lanStateKnown = true
    T3ConnectionPreferences.save(endpoint, to: defaults)
  }

  private func reconcileLAN(generation current: UUID) async -> Bool {
    do {
      let result: LANStatus = try await admin("lan")
      guard generation == current else { return false }
      try applyLANStatus(result)
      return true
    } catch { return false }
  }

  func refreshLAN() async {
    guard !lanBusy, port != nil else { return }
    let current = generation
    lanBusy = true
    defer { if generation == current { lanBusy = false } }
    if await reconcileLAN(generation: current) {
      lanMessage = lanEndpoint == nil ? "已确认局域网入口关闭。" : "已确认局域网入口正在监听。"
    } else if generation == current {
      lanStateKnown = false
      lanPairing = nil
      lanMessage = "无法读取入口状态，请检查服务后重试。"
    }
  }

  func generateLANPairing() async {
    guard !lanBusy, lanStateKnown, lanEndpoint != nil else { return }
    let current = generation
    lanBusy = true
    lanPairing = nil
    defer { if generation == current { lanBusy = false } }
    do {
      let pairing: T3Pairing = try await admin("pairing", method: "POST", body: [:])
      guard generation == current else { return }
      lanPairing = pairing
      lanMessage = "配对凭据只供你的设备使用，勿发送给他人。"
    } catch {
      if generation == current { lanMessage = "无法生成配对凭据，请重试。" }
    }
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
      let result: Revocation = try await admin(
        "revoke-client", method: "POST", body: ["sessionId": id])
      let values: [T3PairedClient] = try await admin("clients")
      guard generation == current else { return }
      clients = values
      guard !values.contains(where: { $0.id == id }) else { throw ServiceError.managementFailed }
      managementMessage = result.revoked ? "设备授权已撤销。" : "设备授权已不存在（可能已撤销或过期）。"
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

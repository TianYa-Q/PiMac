import Combine
import Foundation

/// Owns T3 transport and private IPC. Network and message-sending consent are separate.
@MainActor
final class T3BridgeService: ObservableObject {
  @Published private(set) var port: Int?
  @Published private(set) var status = "未启用"
  @Published private(set) var isEnabled = false
  @Published private(set) var isStopping = false
  @Published private(set) var rememberedNetwork: T3NetworkEndpoint?
  @Published var allowsMessageSending = false {
    didSet { defaults.set(allowsMessageSending, forKey: "t3AllowsMessageSending") }
  }
  private let commands = T3WorkspaceCommands()
  private let defaults: UserDefaults
  private let stateDirectory: URL?
  private var stoppingPID: Int32?
  @Published private(set) var publicURL: URL?
  @Published private(set) var pairing: T3Pairing?
  @Published private(set) var clients: [T3PairedClient] = []
  @Published private(set) var readDiagnostics: T3ReadDiagnostics?
  @Published private(set) var managementBusy = false
  private var clientRefreshID: UUID?
  @Published private(set) var managementMessage = ""
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
    allowsMessageSending = defaults.bool(forKey: "t3AllowsMessageSending")
  }

  /// Only user actions clear consent. Process shutdown/failure preserves it.
  func forgetNetworkPreference() {
    rememberedNetwork = nil
    T3ConnectionPreferences.save(nil, to: defaults)
  }

  func disable() {
    forgetNetworkPreference()
    stop()
  }

  @discardableResult
  func restoreRememberedConnection(workspace: WorkspaceModel) -> Bool {
    guard let network = rememberedNetwork else { return false }
    enable(workspace: workspace, network: network)
    return true
  }

  var connectionURL: URL? {
    publicURL ?? port.flatMap { URL(string: "http://127.0.0.1:\($0)") }
  }

  func enable(workspace: WorkspaceModel, network: T3NetworkEndpoint?) {
    // Called after explicit consent (or restoration of that same consent).
    // Retain the preference even if Node/listen fails; never pick another IP.
    rememberedNetwork = network
    T3ConnectionPreferences.save(network, to: defaults)
    do {
      try start(
        workspace: workspace, token: T3NetworkEndpoint.secret(),
        stateDirectory: stateDirectory, network: network)
    } catch {
      stop()
      status = "无法启动：请检查 Node、IP 地址、端口及服务锁（详见集成文档）。"
    }
  }
  private var process: Process?
  private var input: FileHandle?
  private var generation = UUID()
  private var bridge: RemoteWorkspaceBridge?
  private var writer = DispatchQueue(label: "pimac.t3.bridge.writer")

  func start(
    workspace: WorkspaceModel, token: String, stateDirectory: URL? = nil,
    network: T3NetworkEndpoint? = nil
  ) throws {
    stop()
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
    bridge = RemoteWorkspaceBridge(
      workspace: workspace, commands: commands,
      canSend: { [weak self] in self?.allowsMessageSending == true && self?.isEnabled == true })
    child.executableURL = URL(fileURLWithPath: "/bin/zsh")
    child.arguments = [
      "-lc", "exec node \"$1\"", "pimac-t3", resource.appendingPathComponent("gateway.mjs").path,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["PIMAC_T3_BRIDGE_TOKEN"] = token
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
      isEnabled = true
      status = "启动中"
      // Own reads for the entire child lifetime instead of relying on FileHandle
      // readability notifications. HTTP/WebSocket health alone does not establish
      // native IPC health. Install only after process/input/generation are ready
      // so the first record cannot be dropped.
      T3BridgePipeReader.start(stdout.fileHandleForReading) { [weak self] record in
        Task { @MainActor [weak self] in self?.receive(record, generation: current) }
      }
      // Drain, but never log stderr: it may contain credentials or prompt text.
      T3BridgePipeReader.start(stderr.fileHandleForReading)
    } catch {
      lease.release()
      bridge = nil
      throw error
    }
  }

  func stop() {
    generation = UUID()
    isEnabled = false
    adminToken = ""
    requestedNetwork = nil
    publicURL = nil
    pairingGeneration = UUID()
    pairing = nil
    clients = []
    readDiagnostics = nil
    clientRefreshID = nil
    managementBusy = false
    managementMessage = ""
    port = nil
    bridge = nil
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
        ? "端口已被占用，请更换端口后重试。" : "IP 地址不可用或监听失败。"
      return
    }
    if let message = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
      message["type"] as? String == "ready", let port = message["port"] as? Int,
      (1...65535).contains(port)
    {
      if let network = requestedNetwork {
        guard message["publicHost"] as? String == network.host,
          message["publicPort"] as? Int == network.port
        else {
          stop()
          status = "网络监听状态不匹配，已停止服务。"
          return
        }
        publicURL = URL(string: "http://\(network.host):\(network.port)")
      }
      self.port = port
      status = publicURL == nil ? "仅本机只读预览（手机不可访问）" : "手机只读预览已启动（尚不支持发送与取消）"
      NSLog("Pi Mac internal T3 bridge listening on 127.0.0.1:%d", port)
      return
    }
    guard let request = try? JSONDecoder().decode(RemoteBridgeRequest.self, from: record) else {
      return
    }
    bridge?.handle(request) { [weak self] response in
      guard let self, self.generation == current, let input = self.input,
        var data = try? JSONSerialization.data(withJSONObject: response)
      else { return }
      data.append(0x0A)
      self.writer.async { try? input.write(contentsOf: data) }
    }
  }

  private func admin<T: Decodable>(
    _ path: String, method: String = "GET",
    body: [String: String]? = nil
  ) async throws -> T {
    guard let port, !adminToken.isEmpty else { throw ServiceError.notRunning }
    let current = generation
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/internal/auth/\(path)")!)
    request.httpMethod = method
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

  private struct Revocation: Decodable { let revoked: Bool }

  func generatePairing(label: String) async {
    guard !managementBusy, clientRefreshID == nil, port != nil else { return }
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
      guard grant.credential.count == 64,
        grant.credential.allSatisfy({ "0123456789abcdef".contains($0) }),
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
      let diagnostics: T3ReadDiagnostics? = try? await admin("read-diagnostics")
      guard generation == current else { return }
      if readDiagnostics != diagnostics { readDiagnostics = diagnostics }
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
    guard !managementBusy, clientRefreshID == nil else { return }
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

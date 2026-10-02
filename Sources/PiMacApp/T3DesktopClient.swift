import Combine
import CryptoKit
import Foundation

/// A T3 client, not an agent manager. Snapshots are authoritative server state.
@MainActor
final class T3DesktopClient: ObservableObject {
  typealias JSON = [String: Any]
  @Published private(set) var isConnected = false
  @Published private(set) var status = "正在启动本机 T3 Server…"
  private(set) var shell: JSON = [:]
  private(set) var providers: [JSON] = []
  var onShell: ((JSON) -> Void)?
  private weak var service: T3BridgeService?
  private var token = ""
  private var loop: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var generation = UUID()
  private var watches: [UUID: (String, (JSON) -> Void)] = [:]
  private var threadRevisions: [String: Int] = [:]
  private var hasDeliveredShell = false
  private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.connectionProxyDictionary = [:]
    config.timeoutIntervalForRequest = 15
    return URLSession(configuration: config)
  }()

  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: "t3DesktopShellCache"),
      let snapshot = try? JSONSerialization.jsonObject(with: data) as? JSON {
      shell = snapshot
    }
  }

  func start(service: T3BridgeService) {
    stop()
    self.service = service
    let current = generation
    loop = Task { [weak self] in
      while let self, !Task.isCancelled, self.generation == current {
        do {
          if self.service?.serverURL == nil {
            let status = self.service?.status ?? "Server 未启动"
            if self.status != status { self.status = status }
          } else {
            if self.token.isEmpty { self.token = try await service.desktopCredential() }
            if self.providers.isEmpty { try await self.loadConfig() }
            try await self.refresh()
            if !self.isConnected { self.isConnected = true }
            if self.status != "T3 Server 已连接" { self.status = "T3 Server 已连接" }
          }
        } catch {
          guard self.generation == current, !Task.isCancelled else { return }
          if self.isConnected { self.isConnected = false }
          let status = "T3 Server 连接中断；命令不会自动重发。"
          if self.status != status { self.status = status }
          if (error as? ClientError) == .unauthorized { self.token = "" }
        }
        try? await Task.sleep(for: .milliseconds(self.hasRunningThread ? 250 : 1000))
      }
    }
  }

  func stop() {
    generation = UUID()
    loop?.cancel()
    loop = nil
    refreshTask?.cancel()
    refreshTask = nil
    token = ""
    isConnected = false
    watches.removeAll()
    threadRevisions.removeAll()
    hasDeliveredShell = false
  }

  var hasRunningThread: Bool {
    threads.contains {
      ($0["latestTurn"] as? JSON)?["state"] as? String == "running"
        || ["starting", "running"].contains(($0["session"] as? JSON)?["status"] as? String ?? "")
    }
  }
  var projects: [JSON] { shell["projects"] as? [JSON] ?? [] }
  var threads: [JSON] { shell["threads"] as? [JSON] ?? [] }
  func thread(_ id: String) -> JSON? { threads.first { $0["id"] as? String == id } }
  func projectID(for url: URL) -> String? {
    projects.first { $0["workspaceRoot"] as? String == url.standardizedFileURL.path }?["id"]
      as? String
  }
  func watch(_ id: String, owner: UUID, receive: @escaping (JSON) -> Void) {
    watches[owner] = (id, receive)
    threadRevisions.removeValue(forKey: id)
    requestRefresh()
  }
  func unwatch(owner: UUID) { watches.removeValue(forKey: owner) }

  func waitUntilReady() async throws {
    for _ in 0..<300 {
      try Task.checkCancellation()
      if isConnected { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ClientError.unavailable
  }

  func request(_ path: String, method: String = "GET", body: JSON? = nil) async throws -> JSON {
    guard let base = service?.serverURL, !token.isEmpty else { throw ClientError.unavailable }
    let current = generation
    var request = URLRequest(url: URL(string: base.absoluteString + path)!)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
    let (data, response) = try await session.data(for: request)
    guard generation == current else { throw CancellationError() }
    guard let status = (response as? HTTPURLResponse)?.statusCode else {
      throw ClientError.unavailable
    }
    if status == 401 {
      token = ""
      throw ClientError.unauthorized
    }
    guard status == 200, data.count <= 32 * 1024 * 1024 else { throw ClientError.rejected }
    return try JSONSerialization.jsonObject(with: data) as? JSON ?? [:]
  }

  @discardableResult
  func dispatch(_ fields: JSON, commandID: String = UUID().uuidString) async throws -> JSON {
    try await waitUntilReady()
    var command = fields
    command["commandId"] = commandID
    if command["createdAt"] == nil { command["createdAt"] = Self.timestamp() }
    // The ID is allocated once per user action. Network failure is an unknown
    // outcome, never permission for the UI to replay or create another thread.
    let result = try await request("/api/orchestration/dispatch", method: "POST", body: command)
    requestRefresh()
    return result
  }

  func ensureProject(_ url: URL) async throws -> String {
    try await waitUntilReady()
    if let id = projectID(for: url) { return id }
    // Stable root identity coalesces desktop startup/project imports.
    let id = Self.projectIdentity(url.standardizedFileURL.path)
    try await dispatch(
      [
        "type": "project.create", "projectId": id,
        "title": url.lastPathComponent, "workspaceRoot": url.standardizedFileURL.path,
      ], commandID: "desktop-project-\(id)")
    return id
  }

  private var refreshing = false
  func refresh() async throws {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    let next = try await request("/api/orchestration/shell")
    applyShell(next)
    for id in Set(watches.values.map { $0.0 }) {
      guard thread(id) != nil else { continue }
      let escaped = id.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%")))!
      let detail = try await request("/api/orchestration/threads/\(escaped)?reasoningMessages=true")
      let revision = detail["snapshotSequence"] as? Int ?? -1
      if threadRevisions[id] == revision { continue }
      threadRevisions[id] = revision
      let callbacks = watches.values.filter { $0.0 == id }.map { $0.1 }
      for callback in callbacks { callback(detail) }
    }
  }
  // Do not invalidate the entire desktop or rewrite its cache on identical polls.
  // The first live snapshot must still be delivered when loaded from disk.
  func applyShell(_ next: JSON) {
    guard !hasDeliveredShell || !NSDictionary(dictionary: shell).isEqual(to: next) else { return }
    hasDeliveredShell = true
    shell = next
    if let data = try? JSONSerialization.data(withJSONObject: next) {
      defaults.set(data, forKey: "t3DesktopShellCache")
    }
    onShell?(next)
  }

  func sessionMetrics(threadID: String) async throws -> SessionStats? {
    guard let service else { throw ClientError.unavailable }
    let key = "t3DesktopMetrics.\(threadID)"
    if let stats = try? await service.sessionMetrics(threadID: threadID) {
      if let data = try? JSONEncoder().encode(stats) { defaults.set(data, forKey: key) }
      return stats
    }
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(SessionStats.self, from: data)
  }

  func accountStatus(threadID: String, provider: String? = nil) async throws -> JSON? {
    guard let service else { throw ClientError.unavailable }
    return try await service.accountStatus(threadID: threadID, provider: provider)
  }

  func requestRefresh() {
    guard refreshTask == nil else { return }
    refreshTask = Task { [weak self] in
      defer { self?.refreshTask = nil }
      try? await self?.refresh()
    }
  }

  func loadConfig() async throws {
    let result = try await rpc("server.getConfig")
    providers = result["providers"] as? [JSON] ?? []
  }
  private func rpc(_ method: String) async throws -> JSON {
    let current = generation
    let ticket = try await request("/api/auth/websocket-ticket", method: "POST", body: [:])
    guard let secret = ticket["ticket"] as? String, let base = service?.serverURL else {
      throw ClientError.unavailable
    }
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    components.scheme = "ws"
    components.path = "/ws"
    components.queryItems = [
      .init(name: "orchestrationProtocol", value: "1"), .init(name: "wsTicket", value: secret),
    ]
    let socket = session.webSocketTask(with: components.url!)
    socket.maximumMessageSize = 16 * 1024 * 1024
    socket.resume()
    let timeout = Task {
      try? await Task.sleep(for: .seconds(15))
      if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
    }
    defer {
      timeout.cancel()
      socket.cancel(with: .normalClosure, reason: nil)
    }
    let id = UUID().uuidString
    try await socket.send(
      .string(
        String(
          decoding: try JSONSerialization.data(withJSONObject: [
            "_tag": "Request", "id": id, "tag": method, "payload": [:], "headers": [],
          ]), as: UTF8.self)))
    while true {
      let frame = try await socket.receive()
      guard generation == current, !Task.isCancelled else { throw CancellationError() }
      let data: Data
      switch frame {
      case .data(let value): data = value
      case .string(let value): data = Data(value.utf8)
      @unknown default: throw ClientError.rejected
      }
      let parsed = try JSONSerialization.jsonObject(with: data)
      for response in (parsed as? [JSON] ?? (parsed as? JSON).map { [$0] } ?? []) {
        if response["_tag"] as? String == "Ping" {
          try await socket.send(.string(#"{"_tag":"Pong"}"#))
          continue
        }
        guard response["_tag"] as? String == "Exit", response["requestId"] as? String == id,
          let exit = response["exit"] as? JSON
        else { continue }
        guard exit["_tag"] as? String == "Success", let value = exit["value"] as? JSON else {
          throw ClientError.rejected
        }
        return value
      }
    }
  }

  // MainActor isolation keeps these reusable formatters serialized.
  private static let timestampFormatter = ISO8601DateFormatter()
  private static let fractionalTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  static func timestamp() -> String { timestampFormatter.string(from: .now) }
  static func date(_ value: Any?) -> Date {
    guard let text = value as? String else { return .distantPast }
    return fractionalTimestampFormatter.date(from: text)
      ?? timestampFormatter.date(from: text) ?? .distantPast
  }
  static func projectIdentity(_ path: String) -> String {
    // Namespace is distinct from thread IDs and legacy file/runtime identifiers.
    "desktop-" + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  enum ClientError: Error { case unavailable, unauthorized, rejected }
}

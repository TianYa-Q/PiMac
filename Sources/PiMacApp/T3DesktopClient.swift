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
  var onTaskStatus: ((TaskStatusTracker.Event) -> Void)?
  private var taskStatusTracker = TaskStatusTracker()
  private weak var service: T3BridgeService?
  private var token = ""
  private var connectedServerURL: URL?
  private var loop: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var generation = UUID()
  private var watches: [UUID: (String, (JSON) -> Void, (JSON) -> Void)] = [:]
  private var imageCache: [String: PromptAttachment] = [:]
  private var threadRevisions: [String: Int] = [:]
  private var hasDeliveredShell = false
  private var syncedModelPreferences: Data?
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
      let snapshot = try? JSONSerialization.jsonObject(with: data) as? JSON
    {
      shell = snapshot
    }
  }

  func start(service: T3BridgeService) {
    stop()
    self.service = service
    let current = generation
    loop = Task { [weak self] in
      while let self, !Task.isCancelled, self.generation == current {
        var phase = "获取桌面凭证"
        do {
          let serverURL = self.service?.serverURL
          if serverURL != self.connectedServerURL {
            self.connectedServerURL = serverURL
            self.token = ""
            self.syncedModelPreferences = nil
            self.providers = []
            self.threadRevisions.removeAll()
            self.isConnected = false
          }
          if serverURL == nil {
            let status = self.service?.status ?? "Server 未启动"
            if self.status != status { self.status = status }
          } else {
            if self.token.isEmpty { self.token = try await service.desktopCredential() }
            phase = "同步模型配置"
            try await self.syncModelPreferences()
            if self.providers.isEmpty { try await self.loadConfig() }
            phase = "读取会话状态"
            try await self.refresh()
            if !self.isConnected { self.isConnected = true }
            if self.status != "T3 Server 已连接" { self.status = "T3 Server 已连接" }
          }
        } catch {
          guard self.generation == current, !Task.isCancelled else { return }
          if self.isConnected { self.isConnected = false }
          let status = Self.connectionFailureStatus(error, phase: phase)
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
    connectedServerURL = nil
    providers = []
    syncedModelPreferences = nil
    isConnected = false
    watches.removeAll()
    threadRevisions.removeAll()
    hasDeliveredShell = false
    taskStatusTracker = TaskStatusTracker()
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
  func watch(
    _ id: String, owner: UUID, receiveUI: @escaping (JSON) -> Void = { _ in },
    receive: @escaping (JSON) -> Void
  ) {
    watches[owner] = (id, receive, receiveUI)
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
    request.setValue("2", forHTTPHeaderField: "x-t3-orchestration-protocol")
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
    if command["type"] as? String == "thread.create"
      || command["type"] as? String == "message.dispatch"
    {
      command["createdBy"] = "user"
      command["creationSource"] = "web"
    }
    // The ID is allocated once per user action. Network failure is an unknown
    // outcome, never permission for the UI to replay or create another thread.
    let result = try await rpc(
      Self.mutationMethod(for: command["type"] as? String), payload: command)
    requestRefresh()
    return result
  }

  func persistAttachments(_ images: [JSON], threadID: String, messageID: String) async throws
    -> [JSON]
  {
    guard !images.isEmpty else { return [] }
    let result = try await rpc(
      "assets.persistChatAttachments",
      payload: ["threadId": threadID, "messageId": messageID, "attachments": images])
    guard let attachments = result["attachments"] as? [JSON] else { throw ClientError.rejected }
    return attachments
  }

  func interrupt(threadID: String) async throws {
    let native = try await request("/api/orchestration/threads/\(threadID)")
    guard let projection = native["projection"] as? JSON,
      let runs = projection["runs"] as? [JSON],
      let run = runs.last(where: {
        ["preparing", "starting", "running", "waiting"].contains($0["status"] as? String ?? "")
      }),
      let runID = run["id"] as? String
    else { throw ClientError.rejected }
    try await dispatch(["type": "run.interrupt", "threadId": threadID, "runId": runID])
  }

  static func mutationMethod(for type: String?) -> String {
    ["project.create", "project.update", "project.delete"].contains(type ?? "")
      ? "projects.mutate" : "orchestration.dispatchCommand"
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
    let current = generation
    let next = try await request("/api/orchestration/shell")
    applyShell(T3V2Presentation.shell(next))
    for id in Set(watches.values.map { $0.0 }) {
      guard thread(id) != nil else { continue }
      let escaped = id.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%")))!
      let nativeDetail = try await request("/api/orchestration/threads/\(escaped)")
      if let stats = T3V2Presentation.stats(nativeDetail),
        let data = try? JSONEncoder().encode(stats)
      {
        defaults.set(data, forKey: "t3DesktopV2Metrics.\(id)")
      }
      let detail = T3V2Presentation.detail(nativeDetail)
      let ui = T3V2Presentation.requests(nativeDetail)
      for callback in watches.values.filter({ $0.0 == id }).map({ $0.2 }) { callback(ui) }
      let revision = detail["snapshotSequence"] as? Int ?? -1
      if threadRevisions[id] == revision { continue }
      let (hydrated, complete) = await hydrateImages(detail)
      guard generation == current else { return }
      if complete { threadRevisions[id] = revision }
      let callbacks = watches.values.filter { $0.0 == id }.map { $0.1 }
      for callback in callbacks { callback(hydrated) }
    }
  }
  // Do not invalidate the entire desktop or rewrite its cache on identical polls.
  // The first live snapshot must still be delivered when loaded from disk.
  func applyShell(_ next: JSON) {
    guard !hasDeliveredShell || !NSDictionary(dictionary: shell).isEqual(to: next) else { return }
    hasDeliveredShell = true
    shell = next
    for event in taskStatusTracker.consume(threads) { onTaskStatus?(event) }
    if let data = try? JSONSerialization.data(withJSONObject: next) {
      defaults.set(data, forKey: "t3DesktopShellCache")
    }
    onShell?(next)
  }

  func sessionMetrics(threadID: String) async throws -> SessionStats? {
    let key = "t3DesktopV2Metrics.\(threadID)"
    if let native = try? await request("/api/orchestration/threads/\(threadID)"),
      let stats = T3V2Presentation.stats(native)
    {
      if let data = try? JSONEncoder().encode(stats) { defaults.set(data, forKey: key) }
      return stats
    }
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(SessionStats.self, from: data)
  }

  func sessionControl(threadID: String, operation: String, accountName: String? = nil) async throws
  {
    let text = try Self.sessionControlText(operation: operation, accountName: accountName)
    try await dispatch([
      "type": "message.dispatch", "threadId": threadID,
      "messageId": UUID().uuidString, "text": text, "attachments": [],
      "dispatchMode": ["type": "start_immediately"],
    ])
  }

  static func isSwitchableAccountName(_ name: String) -> Bool {
    name.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil
      && !name.contains("\n") && !name.contains("\r")
  }

  static func sessionControlText(operation: String, accountName: String? = nil) throws -> String {
    switch operation {
    case "compact": return "/compact"
    case "manage-accounts": return "/accounts"
    case "switch-account":
      guard let accountName, isSwitchableAccountName(accountName) else {
        throw ClientError.rejected
      }
      return "/accounts switch \(accountName)"
    default: throw ClientError.rejected
    }
  }

  func extensionResponse(
    threadID: String, id: String, value: String?, confirmed: Bool?, cancelled: Bool
  ) async throws {
    let native = try await request("/api/orchestration/threads/\(threadID)")
    guard let projection = native["projection"] as? JSON,
      let item = (projection["turnItems"] as? [JSON])?.first(where: {
        $0["requestId"] as? String == id
      })
    else { throw ClientError.rejected }
    var command: JSON = ["type": "runtime-request.respond", "threadId": threadID, "requestId": id]
    if item["type"] as? String == "approval_request" {
      command["decision"] = cancelled ? "cancel" : confirmed == true ? "accept" : "decline"
    } else {
      let questions = item["questions"] as? [JSON] ?? []
      guard let questionID = questions.first?["id"] as? String, questions.count == 1 else {
        throw ClientError.rejected
      }
      command["answers"] = cancelled ? [:] : [questionID: value ?? ""]
    }
    try await dispatch(command)
  }

  func accountStatus(threadID: String, provider: String? = nil, force: Bool = false) async throws
    -> JSON?
  {
    guard let service, let provider, ["openai", "openai-codex", "antigravity"].contains(provider)
    else { return nil }
    return try await service.accountStatus(provider: provider, force: force)
  }

  func requestRefresh() {
    guard refreshTask == nil else { return }
    refreshTask = Task { [weak self] in
      defer { self?.refreshTask = nil }
      try? await self?.refresh()
    }
  }

  func syncModelPreferences() async throws {
    guard let service else { throw ClientError.unavailable }
    let hidden = (defaults.stringArray(forKey: "t3HiddenModels") ?? []).sorted()
    let model = defaults.string(forKey: "defaultNewSessionModelID")
    let data = try JSONSerialization.data(
      withJSONObject: [
        "hiddenModels": hidden, "defaultModel": model as Any? ?? NSNull(),
      ], options: [.sortedKeys])
    guard data != syncedModelPreferences else { return }
    try await service.syncModelPreferences(hiddenModels: hidden, defaultModel: model)
    try await loadConfig()
    syncedModelPreferences = data
  }

  func loadConfig() async throws {
    let result = try await rpc("server.getConfig")
    let catalogs = try await service?.modelCatalog() ?? [:]
    providers = (result["providers"] as? [JSON] ?? []).map { provider in
      var nativeProvider = provider
      if let id = provider["instanceId"] as? String, let models = catalogs[id] {
        nativeProvider["models"] = models
      }
      return nativeProvider
    }
  }
  func scheduledTasksRPC(_ method: String, payload: JSON = [:]) async throws -> JSON {
    guard
      [
        "scheduledTasks.list", "scheduledTasks.upsert", "scheduledTasks.setEnabled",
        "scheduledTasks.delete", "scheduledTasks.runNow",
      ].contains(method)
    else { throw ClientError.rejected }
    guard isConnected else { throw ClientError.unavailable }
    return try await rpc(method, payload: payload)
  }

  func gitRPC(_ method: String, payload: JSON) async throws -> JSON {
    guard
      [
        "vcs.refreshStatus", "vcs.listRefs", "vcs.pull", "vcs.createRef", "vcs.switchRef",
        "review.getDiffPreview",
      ].contains(method)
    else { throw ClientError.rejected }
    guard isConnected else { throw ClientError.unavailable }
    return try await rpc(method, payload: payload, timeoutSeconds: 120)
  }

  func gitAction(payload: JSON, progress: @escaping (JSON) -> Void) async throws -> JSON {
    guard isConnected else { throw ClientError.unavailable }
    var result: JSON?
    var failed = false
    _ = try await rpc("git.runStackedAction", payload: payload, timeoutSeconds: 300) { event in
      progress(event)
      if event["kind"] as? String == "action_finished" { result = event["result"] as? JSON }
      if event["kind"] as? String == "action_failed" { failed = true }
    }
    guard !failed, let result else { throw ClientError.rejected }
    return result
  }

  private func rpc(
    _ method: String, payload: JSON = [:], timeoutSeconds: Int = 15,
    receive: ((JSON) -> Void)? = nil
  ) async throws -> JSON {
    let current = generation
    let ticket = try await request("/api/auth/websocket-ticket", method: "POST", body: [:])
    guard let secret = ticket["ticket"] as? String, let base = service?.serverURL else {
      throw ClientError.unavailable
    }
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    components.scheme = "ws"
    components.path = "/ws"
    components.queryItems = [
      .init(name: "orchestrationProtocol", value: "2"), .init(name: "wsTicket", value: secret),
    ]
    let socket = session.webSocketTask(with: components.url!)
    socket.maximumMessageSize = 16 * 1024 * 1024
    socket.resume()
    let timeout = Task {
      try? await Task.sleep(for: .seconds(timeoutSeconds))
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
            "_tag": "Request", "id": id, "tag": method, "payload": payload, "headers": [],
          ]), as: UTF8.self)))
    while true {
      let frame = try await withTaskCancellationHandler {
        try await socket.receive()
      } onCancel: {
        socket.cancel(with: .goingAway, reason: nil)
      }
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
        guard response["requestId"] as? String == id else { continue }
        if response["_tag"] as? String == "Chunk" {
          for event in response["values"] as? [JSON] ?? [] { receive?(event) }
          let ack: JSON = ["_tag": "Ack", "requestId": id]
          try await socket.send(
            .string(
              String(decoding: try JSONSerialization.data(withJSONObject: ack), as: UTF8.self)))
          continue
        }
        guard response["_tag"] as? String == "Exit", let exit = response["exit"] as? JSON
        else { continue }
        guard exit["_tag"] as? String == "Success" else { throw ClientError.rejected }
        return exit["value"] as? JSON ?? [:]
      }
    }
  }

  private func hydrateImages(_ detail: JSON) async -> (JSON, Bool) {
    var detail = detail
    guard var thread = detail["thread"] as? JSON else { return (detail, true) }
    var complete = true
    var downloads = 0
    func attachments(_ descriptors: [JSON]) async -> [PromptAttachment] {
      var result: [PromptAttachment] = []
      for descriptor in descriptors {
        guard let id = descriptor["id"] as? String, let base = service?.serverURL else { continue }
        let key = base.absoluteString + id
        if let cached = imageCache[key] {
          result.append(cached)
          continue
        }
        guard downloads < 8 else {
          complete = false
          continue
        }
        downloads += 1
        do {
          let image = try await downloadImage(descriptor)
          imageCache[key] = image
          result.append(image)
        } catch { complete = false }
      }
      return result
    }
    var activities = thread["activities"] as? [JSON] ?? []
    for index in activities.indices {
      var payload = activities[index]["payload"] as? JSON ?? [:]
      var data = payload["data"] as? JSON ?? [:]
      if let images = data["images"] as? [JSON], !images.isEmpty {
        data["localImages"] = await attachments(images)
        payload["data"] = data
        activities[index]["payload"] = payload
      }
    }
    thread["activities"] = activities
    var messages = thread["messages"] as? [JSON] ?? []
    for index in messages.indices {
      if let images = messages[index]["attachments"] as? [JSON], !images.isEmpty {
        messages[index]["localImages"] = await attachments(
          images.filter { $0["type"] as? String == "image" })
      }
    }
    thread["messages"] = messages
    detail["thread"] = thread
    return (detail, complete)
  }

  private func downloadImage(_ descriptor: JSON) async throws -> PromptAttachment {
    guard let base = service?.serverURL, let id = descriptor["id"] as? String,
      let mime = descriptor["mimeType"] as? String,
      let size = descriptor["sizeBytes"] as? Int, size > 0, size <= T3ToolImageCache.maxBytes,
      T3ToolImageCache.fileExtension(mime) != nil
    else { throw ClientError.rejected }
    let cacheKey = id
    if let cached = T3ToolImageCache.cached(key: cacheKey, mimeType: mime, size: size) {
      return cached
    }
    let signed = try await rpc(
      "assets.createUrl", payload: ["resource": ["_tag": "attachment", "attachmentId": id]])
    guard let relative = signed["relativeUrl"] as? String, relative.hasPrefix("/api/assets/"),
      let url = URL(string: base.absoluteString + relative), url.host == base.host,
      url.port == base.port
    else { throw ClientError.rejected }
    let current = generation
    let (bytes, response) = try await session.bytes(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ClientError.rejected }
    var data = Data()
    for try await byte in bytes {
      guard data.count < size else { throw ClientError.rejected }
      data.append(byte)
    }
    guard generation == current, data.count == size else { throw ClientError.rejected }
    return try T3ToolImageCache.store(data, key: cacheKey, mimeType: mime)
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
  // Use only fixed categories, never server error bodies, URLs or credentials.
  static func connectionFailureStatus(_ error: Error, phase: String) -> String {
    let reason: String
    if let error = error as? URLError {
      switch error.code {
      case .timedOut: reason = "请求超时"
      case .cannotConnectToHost, .networkConnectionLost: reason = "本机服务暂不可达"
      default: reason = "网络请求失败"
      }
    } else if (error as? ClientError) == .unauthorized {
      reason = "授权已失效"
    } else if (error as? ClientError) == .rejected {
      reason = "服务拒绝请求"
    } else {
      reason = "初始化请求失败"
    }
    return "T3 Server 连接失败（\(phase)：\(reason)）；正在重试，命令不会自动重发。"
  }

  enum ClientError: Error { case unavailable, unauthorized, rejected }
}

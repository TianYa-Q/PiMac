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
  private(set) var modelContextSettings = ModelContextSettings.empty
  let textGenerationModels = TextGenerationModelStore()
  var modelContextWindows: [String: Int] { modelContextSettings.overrides }
  var onShell: ((JSON) -> Void)?
  var onTaskStatus: ((TaskStatusTracker.Event) -> Void)?
  private var taskStatusTracker = TaskStatusTracker()
  private weak var service: T3BridgeService?
  private var token = ""
  private var connectedServerURL: URL?
  private var loop: Task<Void, Never>?
  private var refreshTask: Task<Void, Error>?
  private var refreshRequested = false
  private var shellRefreshTask: Task<Void, Error>?
  private var shellRefreshRequested = false
  private var generation = UUID()
  private var watches: [UUID: ThreadWatch] = [:]
  private var imageCache: [String: PromptAttachment] = [:]
  private var replyImageCache: [String: [PromptAttachment]] = [:]
  private var toolDetailCache: [String: JSON] = [:]
  private var imageFailures: [String: Int] = [:]
  private var htmlDocumentCache: [String: String] = [:]
  private var htmlRetryAfter: [String: Date] = [:]
  private let searchIndex = ServerSessionSearchIndex()
  private var hasDeliveredShell = false
  private let sessionCatalog = SessionCatalogCache()

  /// 每次 watch 都创建独立对象；刷新期间取消、重新订阅，不会误确认新订阅已收到快照。
  final class ThreadWatch {
    let threadID: String
    let receive: (JSON) -> Void
    let receiveUI: (JSON) -> Void
    private(set) var deliveredSnapshot: Data?

    init(threadID: String, receive: @escaping (JSON) -> Void, receiveUI: @escaping (JSON) -> Void) {
      self.threadID = threadID
      self.receive = receive
      self.receiveUI = receiveUI
    }

    func deliver(_ detail: JSON, fingerprint: Data, complete: Bool) {
      // 先记账再回调；回调可能重新订阅或使附件缓存失效，不能在返回后覆盖其结果。
      deliveredSnapshot = complete ? fingerprint : nil
      receive(detail)
    }

    func invalidate() { deliveredSnapshot = nil }
  }

  static func snapshotFingerprint(_ snapshot: JSON) throws -> Data {
    // JSON 字典顺序无语义，规范化后只保存摘要，避免为每个页面保留完整转录副本。
    let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
    return Data(SHA256.hash(data: data))
  }

  private func invalidateThreadSnapshots() {
    for observer in watches.values { observer.invalidate() }
  }

  static func pollIntervalMilliseconds(hasRunningThread: Bool) -> Int {
    hasRunningThread ? 500 : 2000
  }

  var sessionCatalogRevision: Int { sessionCatalog.rebuildCount }

  func sessions(projectID: String) -> [SessionItem] {
    sessionCatalog.sessions(projectID: projectID)
  }
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
      sessionCatalog.update(threads: threads)
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
            self.modelContextSettings = .empty
            self.textGenerationModels.reset()
            self.invalidateThreadSnapshots()
            self.searchIndex.reset()
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
        try? await Task.sleep(
          for: .milliseconds(Self.pollIntervalMilliseconds(hasRunningThread: self.hasRunningThread))
        )
      }
    }
  }

  func stop() {
    searchIndex.reset()
    generation = UUID()
    loop?.cancel()
    loop = nil
    refreshTask?.cancel()
    refreshTask = nil
    refreshRequested = false
    shellRefreshTask?.cancel()
    shellRefreshTask = nil
    shellRefreshRequested = false
    token = ""
    connectedServerURL = nil
    providers = []
    modelContextSettings = .empty
    textGenerationModels.reset()
    syncedModelPreferences = nil
    isConnected = false
    watches.removeAll()
    imageCache.removeAll()
    replyImageCache.removeAll()
    toolDetailCache.removeAll()
    htmlDocumentCache.removeAll()
    htmlRetryAfter.removeAll()
    imageFailures.removeAll()
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
    watches[owner] = ThreadWatch(threadID: id, receive: receive, receiveUI: receiveUI)
    // Reopening a thread retries failed images without re-downloading successful ones.
    for key in imageFailures.keys {
      toolDetailCache.removeValue(forKey: key)
      replyImageCache.removeValue(forKey: key)
    }
    imageFailures.removeAll()
    htmlRetryAfter.removeAll()
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
  func dispatch(
    _ fields: JSON, commandID: String = UUID().uuidString, refreshAfter: Bool = true
  ) async throws -> JSON {
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
    if refreshAfter { requestRefresh() }
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

  func interrupt(threadID: String, runID: String) async throws {
    // thread.stop 是 Server 内部命令；公开接口用 run.interrupt，holdQueue 同时阻止排队消息继续执行。
    try await dispatch([
      "type": "run.interrupt", "threadId": threadID, "runId": runID, "holdQueue": true,
    ])
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

  func refresh() async throws {
    // 刷新途中可能刚提交 Settle；当前快照不一定包含该写入，必须保留一次后续读取。
    // 并发请求合并到同一任务，调用方等待完整刷新，而不是将“正在刷新”当作成功。
    refreshRequested = true
    if let refreshTask {
      try await refreshTask.value
      return
    }
    let current = generation
    let task = Task {
      // 在任务返回前清除句柄，避免新请求误加入已完成、但调用方尚未清理的任务。
      defer {
        if self.generation == current { self.refreshTask = nil }
      }
      while self.generation == current, self.refreshRequested {
        try Task.checkCancellation()
        self.refreshRequested = false
        try await self.refreshSnapshot()
      }
    }
    refreshTask = task
    try await task.value
  }

  /// 生命周期确认只依赖列表，不应等待所有打开会话的转录、工具详情和图片下载。
  /// 写入发生在读取途中时保留一次后续读取；与完整轮询共享列表请求，避免刷新风暴。
  func refreshShell() async throws {
    shellRefreshRequested = true
    if let shellRefreshTask {
      try await shellRefreshTask.value
      return
    }
    let current = generation
    let task = Task {
      defer {
        if self.generation == current { self.shellRefreshTask = nil }
      }
      while self.generation == current, self.shellRefreshRequested {
        try Task.checkCancellation()
        self.shellRefreshRequested = false
        let next = try await self.request("/api/orchestration/shell")
        self.applyShell(T3V2Presentation.shell(next))
      }
    }
    shellRefreshTask = task
    try await task.value
  }

  private func refreshSnapshot() async throws {
    let current = generation
    try await refreshShell()
    for id in Set(watches.values.map { $0.threadID }) {
      guard thread(id) != nil else { continue }
      let escaped = id.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%")))!
      let nativeDetail = try await request("/api/orchestration/threads/\(escaped)")
      guard generation == current else { return }
      // 快照含继承历史等跨线程派生数据，当前线程的事件序号不能完整代表内容。
      // 按实际载荷去重，且每个观察者独立确认，避免新订阅被旧订阅的缓存跳过。
      let fingerprint = try Self.snapshotFingerprint(nativeDetail)
      let observers = watches.filter {
        $0.value.threadID == id && $0.value.deliveredSnapshot != fingerprint
      }
      if observers.isEmpty { continue }
      if let stats = T3V2Presentation.stats(nativeDetail),
        let data = try? JSONEncoder().encode(stats)
      {
        defaults.set(data, forKey: "t3DesktopV2Metrics.\(id)")
      }
      guard let base = service?.serverURL else { return }
      let (richNative, toolsComplete) = await hydrateToolImages(
        nativeDetail, threadID: id, base: base,
        performRPC: { try await self.rpc($0, payload: $1) },
        loadHTML: { try await self.htmlRenderDocument($0) })
      let detail = T3V2Presentation.detail(richNative)
      let ui = T3V2Presentation.requests(nativeDetail)
      for (owner, observer) in observers where watches[owner] === observer {
        observer.receiveUI(ui)
      }
      let (withReplies, repliesComplete) = await hydrateReplyImages(detail, threadID: id)
      let (hydrated, complete) = await hydrateImages(withReplies)
      guard generation == current else { return }
      for (owner, observer) in observers where watches[owner] === observer {
        observer.deliver(
          hydrated, fingerprint: fingerprint,
          complete: complete && repliesComplete && toolsComplete)
      }
    }
  }
  // Do not invalidate the entire desktop or rewrite its cache on identical polls.
  // The first live snapshot must still be delivered when loaded from disk.
  func applyShell(_ next: JSON) {
    guard !hasDeliveredShell || !NSDictionary(dictionary: shell).isEqual(to: next) else { return }
    hasDeliveredShell = true
    shell = next
    sessionCatalog.update(threads: threads)
    for event in taskStatusTracker.consume(threads) { onTaskStatus?(event) }
    if let data = try? JSONSerialization.data(withJSONObject: next) {
      defaults.set(data, forKey: "t3DesktopShellCache")
    }
    onShell?(next)
  }

  func sessionSearchMessages(query: String, sessions: [SessionItem]) async throws
    -> [String: [String]]
  {
    let current = generation
    return try await searchIndex.messages(for: query, in: sessions) { id in
      guard self.generation == current, self.isConnected else { throw ClientError.unavailable }
      let escaped = id.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%")))!
      let native = try await self.request("/api/orchestration/threads/\(escaped)")
      guard self.generation == current else { throw CancellationError() }
      let detail = T3V2Presentation.detail(native)
      guard let thread = detail["thread"] as? JSON,
        let messages = thread["messages"] as? [JSON]
      else { throw ClientError.rejected }
      return messages.compactMap { message in
        guard let role = message["role"] as? String, ["user", "assistant"].contains(role),
          let text = message["text"] as? String, !text.isEmpty
        else { return nil }
        return text
      }
    }
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
    try await dispatch(Self.sessionControlCommand(
      threadID: threadID, messageID: UUID().uuidString,
      operation: operation, accountName: accountName))
  }

  static func sessionControlCommand(
    threadID: String, messageID: String, operation: String, accountName: String?
  ) throws -> JSON {
    let text = try sessionControlText(operation: operation, accountName: accountName)
    var command: JSON = [
      "type": "message.dispatch", "threadId": threadID,
      "messageId": messageID, "text": text, "attachments": [],
      "dispatchMode": ["type": "start_immediately"],
    ]
    // Server 在线程锁内选择空闲启动或活跃 steering。仅提交 /accounts：
    // Pi 优先执行扩展命令，不把管理请求排到当前任务结束，也不停止任务。
    // 切换/登录的空闲限制仍由各自的入口及扩展检查。
    if operation == "manage-accounts" { command["deliveryIntent"] = "steer" }
    return command
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

  func accountStatus(
    threadID: String, provider: String? = nil, force: Bool = false, selectionOnly: Bool = false
  ) async throws
    -> JSON?
  {
    guard let service, let provider, ["openai", "openai-codex", "antigravity"].contains(provider)
    else { return nil }
    return try await service.accountStatus(
      threadID: threadID, provider: provider, force: force, selectionOnly: selectionOnly)
  }

  func requestRefresh() {
    if refreshTask != nil {
      refreshRequested = true
      return
    }
    Task { [weak self] in
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

  func updateTextGenerationModel(_ modelID: String?) async {
    await textGenerationModels.update(refresh: modelID == nil) { [self] in
      guard let service else { throw ClientError.unavailable }
      // 保存之前先同步本机隐藏列表，避免刚隐藏的模型仍被列为候选。
      try await syncModelPreferences()
      return try await service.textGenerationModelSettings(modelID: modelID)
    }
  }

  func loadConfig() async throws {
    let result = try await rpc("server.getConfig")
    let catalogs = try await service?.modelCatalog() ?? [:]
    modelContextSettings = try await service?.modelContextSettings() ?? .empty
    if let service {
      await textGenerationModels.update(refresh: true) {
        try await service.textGenerationModelSettings(modelID: nil)
      }
    }
    providers = (result["providers"] as? [JSON] ?? []).map { provider in
      var nativeProvider = provider
      if let id = provider["instanceId"] as? String, let models = catalogs[id] {
        nativeProvider["models"] = models
      }
      return nativeProvider
    }
  }
  func setModelContextWindow(_ tokens: Int?, modelID: String) async throws {
    guard let service else { throw ClientError.unavailable }
    modelContextSettings = try await service.setModelContextWindow(tokens, modelID: modelID)
  }

  func usageSummary(period: UsagePeriod) async throws -> UsageSnapshot {
    try await waitUntilReady()
    let summary = try await rpc(
      "server.getUsageSummary", payload: T3UsageSummary.input(period: period), timeoutSeconds: 120)
    try Task.checkCancellation()
    return try T3UsageSummary.snapshot(summary, period: period)
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

  /// Timeline snapshots deliberately omit output. Use official lazy detail reads,
  /// then download raster images through signed assets without putting bytes in chat text.
  func hydrateToolImages(
    _ native: JSON, threadID: String, base: URL,
    performRPC: (String, JSON) async throws -> JSON,
    loadHTML: (T3HTMLRender) async throws -> String
  ) async -> (JSON, Bool) {
    var native = native
    guard var projection = native["projection"] as? JSON,
      var rows = projection["visibleTurnItems"] as? [JSON]
    else { return (native, true) }
    let current = generation
    var complete = true
    var reads = 0
    var downloads = 0
    itemLoop: for index in rows.indices {
      guard var item = rows[index]["item"] as? JSON,
        item["type"] as? String == "dynamic_tool",
        !T3V2Presentation.active.contains(item["status"] as? String ?? ""),
        let id = item["id"] as? String, let revision = item["updatedAt"] as? String
      else { continue }
      let ownerThreadID = item["threadId"] as? String ?? threadID
      let key = "\(base.absoluteString)|\(ownerThreadID)|\(id)|\(revision)"
      if let cached = toolDetailCache[key] {
        rows[index]["item"] = cached
        guard let retryAfter = htmlRetryAfter[key] else { continue }
        if retryAfter > Date() {
          complete = false
          continue
        }
      }
      guard reads < 8 else {
        complete = false
        continue
      }
      reads += 1
      var images: [PromptAttachment] = []
      // 即使详情请求失败，也保留快照里的有效引用，让最终失败能显示而非无限留白。
      item["htmlRender"] =
        T3HTMLRender.read(
          toolName: item["toolName"] as? String ?? "", output: item["output"])
        ?? toolDetailCache[key]?["htmlRender"] as? T3HTMLRender
      let toolName = item["toolName"] as? String ?? ""
      let isHTML = T3HTMLRender.isRenderTool(toolName)
      do {
        // 快照已给出有效引用时直接下载，不让详情接口的暂时失败阻塞页面。
        let detail: JSON
        if item["htmlRender"] is T3HTMLRender {
          // 重试时引用可能来自上次详情，原快照依然没有 output。
          detail = item
        } else {
          let response = try await performRPC(
            "orchestration.getTurnItem",
            ["threadId": ownerThreadID, "itemId": id, "revision": revision])
          guard let fetched = response["item"] as? JSON else { throw ClientError.rejected }
          detail = fetched
        }
        // 完成快照可能领先于详情持久化；缺失输出不是合法的“没有页面”。
        if isHTML, item["status"] as? String == "completed",
          item["htmlRender"] == nil,
          detail["output"] == nil || detail["output"] is NSNull
            || T3V2Presentation.active.contains(detail["status"] as? String ?? "")
        {
          throw ClientError.rejected
        }
        if let page = item["htmlRender"] as? T3HTMLRender
          ?? T3HTMLRender.read(toolName: toolName, output: detail["output"])
        {
          item["htmlRender"] = page
          item["htmlDocument"] = try await loadHTML(page)
        }
        for (imageIndex, mime) in T3ToolOutputImages.mimeTypes(detail["output"]).enumerated() {
          let imageKey = "\(key)|\(imageIndex)"
          if let cached = imageCache[imageKey] {
            images.append(cached)
            continue
          }
          guard downloads < 8 else {
            complete = false
            item["localImages"] = images
            rows[index]["item"] = item
            continue itemLoop
          }
          downloads += 1
          let signed = try await performRPC(
            "assets.createUrl",
            [
              "resource": [
                "_tag": "tool-output-image", "threadId": ownerThreadID, "itemId": id,
                "index": imageIndex,
              ]
            ])
          let image = try await downloadReplyImage(signed, key: imageKey, mime: mime)
          guard generation == current else { return (native, false) }
          imageCache[imageKey] = image
          images.append(image)
        }
        item["localImages"] = images
      } catch {
        item["localImages"] = images
        let attempts = (imageFailures[key] ?? 0) + 1
        imageFailures[key] = attempts
        guard generation == current, !Task.isCancelled else { return (native, false) }
        if isHTML {
          // HTML 失败不能提交 revision，否则当前打开会话永远不会恢复。
          // 前三次随正常轮询重试，之后降频；每轮读取预算仍限制为八条。
          complete = false
          if item["htmlRender"] is T3HTMLRender, attempts >= 3 {
            item["htmlRenderError"] = "HTML 页面加载失败"
          }
          htmlRetryAfter[key] = Date().addingTimeInterval(attempts < 3 ? 0 : 10)
          toolDetailCache[key] = item
          rows[index]["item"] = item
          continue
        }
        if attempts < 3 {
          complete = false
          rows[index]["item"] = item
          continue
        }
      }
      guard generation == current else { return (native, false) }
      htmlRetryAfter.removeValue(forKey: key)
      toolDetailCache[key] = item
      rows[index]["item"] = item
    }
    projection["visibleTurnItems"] = rows
    native["projection"] = projection
    return (native, complete)
  }

  /// Reply file links use the same official media assets as the iOS client.
  private func hydrateReplyImages(_ detail: JSON, threadID: String) async -> (JSON, Bool) {
    var detail = detail
    guard var thread = detail["thread"] as? JSON,
      var messages = thread["messages"] as? [JSON], let base = service?.serverURL
    else { return (detail, true) }
    let current = generation
    var complete = true
    var downloads = 0
    for index in messages.indices {
      guard messages[index]["role"] as? String == "assistant",
        messages[index]["streaming"] as? Bool != true,
        let text = messages[index]["text"] as? String,
        let id = messages[index]["id"] as? String
      else { continue }
      let paths = T3ReplyImageLinks.paths(in: text)
      guard !paths.isEmpty else { continue }
      let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
      let key = "\(base.absoluteString)|\(threadID)|\(id)|\(digest)"
      if let cached = replyImageCache[key] {
        messages[index]["localImages"] = cached
        continue
      }
      var images: [PromptAttachment] = []
      var messageComplete = true
      for path in paths {
        let imageKey = "\(base.absoluteString)|\(threadID)|\(id)|\(path)"
        if let cached = imageCache[imageKey] {
          images.append(cached)
          continue
        }
        guard downloads < 8 else {
          messageComplete = false
          break
        }
        downloads += 1
        do {
          let signed = try await rpc(
            "assets.createUrl",
            payload: [
              "resource": [
                "_tag": "media-file", "threadId": threadID, "path": path,
              ]
            ])
          var image = try await downloadReplyImage(
            signed, key: imageKey,
            mime: T3ReplyImageLinks.mimeType(path)!)
          image.replyImagePath = path
          guard generation == current else { return (detail, false) }
          imageCache[imageKey] = image
          images.append(image)
        } catch {
          // Retry transient errors, but missing/invalid files cannot cause endless polls.
          let attempts = (imageFailures[key] ?? 0) + 1
          imageFailures[key] = attempts
          if attempts < 3 { messageComplete = false }
          continue
        }
      }
      guard generation == current else { return (detail, false) }
      messages[index]["localImages"] = images
      if messageComplete { replyImageCache[key] = images } else { complete = false }
    }
    thread["messages"] = messages
    detail["thread"] = thread
    return (detail, complete)
  }

  /// 只使用官方签名附件接口下载页面，避免把服务凭据或本地文件访问权限交给网页。
  func htmlRenderDocument(_ reference: T3HTMLRender) async throws -> String {
    guard let base = service?.serverURL else { throw ClientError.rejected }
    let current = generation
    let key = "\(base.absoluteString)|\(reference.attachmentID)"
    if let cached = htmlDocumentCache[key] { return cached }
    let signed = try await rpc(
      "assets.createUrl",
      payload: [
        "resource": [
          "_tag": "attachment", "attachmentId": reference.attachmentID,
          "mimeType": "text/html", "disposition": "inline",
        ]
      ])
    guard let relative = signed["relativeUrl"] as? String, relative.hasPrefix("/api/assets/"),
      let url = URL(string: base.absoluteString + relative), url.host == base.host,
      url.port == base.port, url.scheme == base.scheme
    else { throw ClientError.rejected }
    let (bytes, response) = try await session.bytes(from: url)
    let limit = 8 * 1024 * 1024
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      response.mimeType == "text/html", response.expectedContentLength <= limit
    else { throw ClientError.rejected }
    var data = Data()
    for try await byte in bytes {
      guard data.count < limit else { throw ClientError.rejected }
      data.append(byte)
    }
    guard generation == current, !Task.isCancelled else { throw CancellationError() }
    guard let html = String(data: data, encoding: .utf8), !html.isEmpty
    else { throw ClientError.rejected }
    // 附件不可变；缓存独立于虚拟列表视图的挂载周期，并限制总内存占用。
    if htmlDocumentCache.values.reduce(0, { $0 + $1.utf8.count }) + data.count > 16 * 1024 * 1024 {
      htmlDocumentCache.removeAll()
    }
    htmlDocumentCache[key] = html
    var recovered = false
    for itemKey in Array(toolDetailCache.keys) {
      guard var item = toolDetailCache[itemKey],
        (item["htmlRender"] as? T3HTMLRender)?.attachmentID == reference.attachmentID,
        item["htmlRenderError"] != nil
      else { continue }
      item["htmlDocument"] = html
      item.removeValue(forKey: "htmlRenderError")
      toolDetailCache[itemKey] = item
      imageFailures.removeValue(forKey: itemKey)
      htmlRetryAfter.removeValue(forKey: itemKey)
      recovered = true
    }
    if recovered {
      invalidateThreadSnapshots()
      requestRefresh()
    }
    return html
  }

  func replyDocumentURL(path: String, threadID: String) async throws -> URL {
    guard let base = service?.serverURL else { throw ClientError.rejected }
    let current = generation
    let signed = try await rpc(
      "assets.createUrl",
      payload: ["resource": ["_tag": "media-file", "threadId": threadID, "path": path]])
    guard generation == current else { throw CancellationError() }
    guard let relative = signed["relativeUrl"] as? String,
      relative.hasPrefix("/api/assets/"),
      let url = URL(string: base.absoluteString + relative),
      url.host == base.host, url.port == base.port, url.scheme == base.scheme
    else { throw ClientError.rejected }
    return url
  }

  func replyImage(path: String, threadID: String) async throws -> PromptAttachment {
    guard let mime = T3ReplyImageLinks.mimeType(path), let base = service?.serverURL else {
      throw ClientError.rejected
    }
    let signed = try await rpc(
      "assets.createUrl",
      payload: [
        "resource": [
          "_tag": "media-file", "threadId": threadID, "path": path,
        ]
      ])
    return try await downloadReplyImage(
      signed,
      key: "\(base.absoluteString)|\(threadID)|\(path)", mime: mime)
  }

  private func downloadReplyImage(_ signed: JSON, key: String, mime: String) async throws
    -> PromptAttachment
  {
    guard let base = service?.serverURL,
      let relative = signed["relativeUrl"] as? String, relative.hasPrefix("/api/assets/"),
      let url = URL(string: base.absoluteString + relative), url.host == base.host,
      url.port == base.port, url.scheme == base.scheme
    else { throw ClientError.rejected }
    let current = generation
    let (bytes, response) = try await session.bytes(from: url)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      response.expectedContentLength <= T3ToolImageCache.maxBytes,
      response.mimeType?.lowercased() == mime
    else { throw ClientError.rejected }
    var data = Data()
    for try await byte in bytes {
      guard data.count < T3ToolImageCache.maxBytes else { throw ClientError.rejected }
      data.append(byte)
    }
    guard generation == current else { throw CancellationError() }
    return try T3ToolImageCache.store(data, key: key, mimeType: mime)
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
        let existing = messages[index]["localImages"] as? [PromptAttachment] ?? []
        messages[index]["localImages"] =
          existing
          + (await attachments(
            images.filter { $0["type"] as? String == "image" }))
      }
    }
    thread["messages"] = messages
    var queued = thread["queuedMessages"] as? [JSON] ?? []
    for index in queued.indices {
      if let images = queued[index]["attachments"] as? [JSON], !images.isEmpty {
        queued[index]["localImages"] = await attachments(
          images.filter { $0["type"] as? String == "image" })
      }
    }
    thread["queuedMessages"] = queued
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

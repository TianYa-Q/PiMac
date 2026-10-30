import Combine
import CryptoKit
import Foundation

/// A T3 client, not an agent manager. Snapshots are authoritative server state.
@MainActor
final class T3DesktopClient: ObservableObject, MessageDeliveryTransport {
  typealias JSON = [String: Any]
  @Published private(set) var isConnected = false
  @Published private(set) var status = "正在启动本机 T3 Server…"
  @Published private(set) var supportsTitleRegeneration = false
  private(set) var shell: JSON = [:]
  private var threadsByID: [String: JSON] = [:]
  private(set) var providers: [JSON] = []
  private(set) var hiddenModelIDs: Set<String> = []
  var onModelsChanged: (() -> Void)?
  private var modelVisibilityRevision = 0
  private var isUpdatingModelVisibility = false
  private(set) var modelContextSettings = ModelContextSettings.empty
  let textGenerationModels = TextGenerationModelStore()
  var modelContextWindows: [String: Int] { modelContextSettings.overrides }
  var onShell: ((JSON) -> Void)?
  var onAccountPoll: (() -> Void)?
  var onTaskStatus: ((TaskStatusTracker.Event) -> Void)?
  private var taskStatusTracker = TaskStatusTracker()
  private weak var service: T3BridgeService?
  private var token = ""
  private var connectedServerURL: URL?
  private var loop: Task<Void, Never>?
  private var connectionLoop: Task<Void, Never>?
  private var serviceReadiness: AnyCancellable?
  private var configurationLoop: Task<Void, Never>?
  private var configurationRevision = UUID()
  private var configurationMaintenance: Task<Void, Never>?
  private var configurationMetadata: Task<Void, Never>?
  private var serverDefaultModelSelection: JSON?
  private var providerCatalogs: [String: [JSON]] = [:]
  private lazy var rpcSession = T3RPCSession { [weak self] in
    guard let self, let base = self.service?.serverURL else { throw ClientError.unavailable }
    let ticket = try await self.request("/api/auth/websocket-ticket", method: "POST", body: [:])
    guard self.service?.serverURL == base, let secret = ticket["ticket"] as? String else {
      throw ClientError.unavailable
    }
    var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    url.scheme = "ws"
    url.path = "/ws"
    url.queryItems = [
      .init(name: "orchestrationProtocol", value: "2"), .init(name: "wsTicket", value: secret),
    ]
    return T3WebSocketConnection(session: self.session, url: url.url!)
  }
  private var connectionCheckRevision = UUID()
  enum RefreshArea: String, CaseIterable {
    case shell = "会话列表"
    case configuration = "模型配置"
    case preferences = "默认模型同步"
    case modelMetadata = "模型元数据"
  }
  private var refreshFailures: [RefreshArea: String] = [:]
  private var connectionFailure: String?
  private(set) var hasLoadedConfiguration = false
  private var configurationEnvironmentID: String?
  private var supportsThreadStop = false
  private let threadRefreshes = ThreadRefreshScheduler()
  private let assetRefreshes = ThreadRefreshScheduler()
  private var shellRefreshTask: Task<Void, Error>?
  private var shellRefreshRequested = false
  private var generation = UUID()
  private(set) var htmlRenderCacheScope = UUID()
  let skillCache = WorkspaceSkillCache()
  private var skillInterests: [UUID: WorkspaceSkillContext] = [:]
  private var hasLiveSkillShell = false
  private let skillDiscovery:
    ((WorkspaceSkillCache.Key, Bool) async throws -> WorkspaceSkillCache.Success)?
  private var watches: [UUID: ThreadWatch] = [:]
  private var projectCreations: [String: Task<String, Error>] = [:]
  private var imageCache: [String: PromptAttachment] = [:]
  private var replyImageCache: [String: [PromptAttachment]] = [:]
  private var toolDetailCache: [String: JSON] = [:]
  private struct ToolHydrationPosition {
    let ownerThreadID: String
    let itemID: String
  }
  private var toolHydrationPositions: [String: ToolHydrationPosition] = [:]
  private var imageFailures: [String: Int] = [:]
  private var htmlRetryAfter: [String: Date] = [:]
  private var hasDeliveredShell = false
  private let sessionCatalog = SessionCatalogCache()

  /// 每次 watch 都创建独立对象；刷新期间取消、重新订阅，不会误确认新订阅已收到快照。
  final class ThreadWatch {
    let threadID: String
    let receive: (JSON) -> Void
    let receiveUI: (JSON) -> Void
    private(set) var deliveredSnapshot: Data?
    private(set) var latestSnapshot: Data?

    init(threadID: String, receive: @escaping (JSON) -> Void, receiveUI: @escaping (JSON) -> Void) {
      self.threadID = threadID
      self.receive = receive
      self.receiveUI = receiveUI
    }

    func deliver(_ detail: JSON, fingerprint: Data, complete: Bool) {
      // 先记账再回调；回调可能重新订阅或使附件缓存失效，不能在返回后覆盖其结果。
      deliveredSnapshot = complete ? fingerprint : nil
      latestSnapshot = fingerprint
      receive(detail)
    }

    func deliverAssets(_ detail: JSON, fingerprint: Data, complete: Bool) {
      guard latestSnapshot == fingerprint else { return }
      deliver(detail, fingerprint: fingerprint, complete: complete)
    }

    func invalidate() {
      deliveredSnapshot = nil
      latestSnapshot = nil
    }
  }

  nonisolated static func snapshotFingerprint(_ snapshot: JSON) throws -> Data {
    // 全局事件游标随其他会话推进，不是当前页面的内容版本；仍比较完整内容，
    // 包括继承历史与分页元数据，不能退化成仅凭当前线程事件序号跳过刷新。
    var content = snapshot
    content.removeValue(forKey: "snapshotSequence")
    let data = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
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

  func sessions(projectID: String?, settled: Bool) -> [SessionItem] {
    sessionCatalog.sessions(projectID: projectID, settled: settled)
  }
  private var syncedDefaultModelPreference: Data?
  // 分开连接池：即使下载占满连接，列表、凭据和命令仍有独立的网络通道。
  private let session = T3DesktopClient.makeSession(maxConnections: 4)
  private let threadSession = T3DesktopClient.makeSession(maxConnections: 4)
  private let assetSession = T3DesktopClient.makeSession(maxConnections: 4)
  // 可用性检查不与配置 RPC、长时间运行的命令或附件争抢连接。
  private let connectionSession: URLSession

  private static func makeSession(maxConnections: Int) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.connectionProxyDictionary = [:]
    config.timeoutIntervalForRequest = 15
    config.httpMaximumConnectionsPerHost = maxConnections
    return URLSession(configuration: config)
  }

  let conversationCache: ConversationPresentationCache
  private let defaults: UserDefaults
  init(
    defaults: UserDefaults = .standard,
    connectionSession: URLSession? = nil,
    skillDiscovery: ((WorkspaceSkillCache.Key, Bool) async throws -> WorkspaceSkillCache.Success)? =
      nil
  ) {
    self.defaults = defaults
    conversationCache = ConversationPresentationCache(defaults: defaults)
    let connectionConfiguration = URLSessionConfiguration.ephemeral
    connectionConfiguration.httpShouldSetCookies = false
    connectionConfiguration.connectionProxyDictionary = [:]
    connectionConfiguration.httpMaximumConnectionsPerHost = 1
    connectionConfiguration.timeoutIntervalForRequest = 3
    connectionConfiguration.timeoutIntervalForResource = 5
    self.connectionSession = connectionSession ?? URLSession(configuration: connectionConfiguration)
    self.skillDiscovery = skillDiscovery
    if let data = defaults.data(forKey: "t3DesktopShellCache"),
      let snapshot = try? JSONSerialization.jsonObject(with: data) as? JSON
    {
      shell = snapshot
      indexThreads()
      sessionCatalog.update(threads: threads)
    }
  }

  func start(service: T3BridgeService) {
    stop()
    self.service = service
    let current = generation
    // ready 事件立即唤醒连接检查；不能让首次连接继续等待下一轮两秒定时器。
    serviceReadiness = service.$serverURL.removeDuplicates().sink { [weak self] _ in
      self?.resumeConnectionChecks()
    }
    loop = Task { [weak self] in
      while let self, !Task.isCancelled, self.generation == current {
        if self.isConnected {
          let serverURL = self.connectedServerURL
          // 会话正文/队列读取不排在全量列表后面；两者有独立连接与合并调度。
          self.requestThreadRefreshes()
          do {
            try await self.refreshShell()
            guard self.generation == current, !Task.isCancelled else { return }
            guard self.connectedServerURL == serverURL else { continue }
            self.recordRefreshResult(.shell, error: nil)
            self.reconcileSkillWorkspaces(now: Date())
            self.onAccountPoll?()
          } catch {
            guard self.generation == current, !Task.isCancelled else { return }
            if self.connectedServerURL == serverURL {
              self.recordRefreshResult(.shell, error: error)
            }
          }
        }
        try? await Task.sleep(
          for: .milliseconds(Self.pollIntervalMilliseconds(hasRunningThread: self.hasRunningThread))
        )
      }
    }
    resumeConfigurationRefreshes()
  }

  private func resumeConfigurationRefreshes() {
    configurationLoop?.cancel()
    configurationRevision = UUID()
    let subscription = configurationRevision
    let current = generation
    configurationMetadata?.cancel()
    configurationMaintenance?.cancel()
    configurationLoop = Task { [weak self] in
      while let self, !Task.isCancelled, self.generation == current {
        if self.isConnected {
          let serverURL = self.connectedServerURL
          do {
            // 与官方客户端相同，先订阅快照，再接增量；不以一次写设置作为配置读取前置条件。
            _ = try await self.rpcSession.call(
              "subscribeServerConfig", payload: ["workspaceSnapshotsOnDemand": true], stream: true
            ) { [weak self] event in
              guard let self, self.generation == current,
                self.configurationRevision == subscription,
                self.connectedServerURL == serverURL
              else { return }
              try self.applyConfigurationEvent(event)
            }
            throw ClientError.unavailable  // 常驻流正常结束也必须重新订阅，不能保留假在线状态。
          } catch {
            guard self.generation == current, !Task.isCancelled else { return }
            if self.connectedServerURL == serverURL {
              self.hasLoadedConfiguration = false
              self.recordRefreshResult(.configuration, error: error)
            }
          }
        }
        try? await Task.sleep(for: .seconds(2))
      }
    }
    configurationMaintenance = Task { [weak self] in
      while let self, !Task.isCancelled, self.generation == current {
        var succeeded = false
        if self.isConnected, self.hasLoadedConfiguration {
          let serverURL = self.connectedServerURL
          do {
            try await self.syncDefaultModelPreference()
            guard self.generation == current, !Task.isCancelled else { return }
            guard self.connectedServerURL == serverURL else { continue }
            self.recordRefreshResult(.preferences, error: nil)
            succeeded = true
          } catch {
            guard self.generation == current, !Task.isCancelled else { return }
            if self.connectedServerURL == serverURL {
              self.recordRefreshResult(.preferences, error: error)
            }
          }
        }
        try? await Task.sleep(for: .seconds(succeeded ? 30 : 2))
      }
    }
  }

  /// 切回前台只唤醒只读检查，不停止会话、不清空缓存，也不重放任何写入。
  func resumeConnectionChecks() {
    guard let service else { return }
    connectionLoop?.cancel()
    connectionCheckRevision = UUID()
    let current = generation
    connectionLoop = Task { [weak self] in
      while let self, !Task.isCancelled, self.generation == current {
        await self.refreshConnection(to: service.serverURL) {
          try await service.desktopCredential()
        }
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  func refreshConnection(
    to serverURL: URL?, credential credentialProvider: () async throws -> String
  ) async {
    let current = generation
    let revision = UUID()
    connectionCheckRevision = revision
    if serverURL != connectedServerURL {
      rpcSession.close()
      configurationMetadata?.cancel()
      providerCatalogs = [:]
      serverDefaultModelSelection = nil
      skillCache.reset()
      hasLiveSkillShell = false
      connectedServerURL = serverURL
      token = ""
      syncedDefaultModelPreference = nil
      modelVisibilityRevision += 1
      hiddenModelIDs = []
      providers = []
      hasLoadedConfiguration = false
      configurationEnvironmentID = nil
      supportsThreadStop = false
      modelContextSettings = .empty
      textGenerationModels.reset()
      invalidateThreadSnapshots()
      refreshFailures.removeAll()
      isConnected = false
    }
    guard let serverURL else {
      isConnected = false
      connectionFailure = service?.status ?? "Server 未启动"
      updateConnectionStatus()
      return
    }
    var phase = "获取桌面凭证"
    do {
      let credential: String
      if token.isEmpty {
        credential = try await credentialProvider()
      } else {
        credential = token
      }
      guard generation == current, connectionCheckRevision == revision, !Task.isCancelled else {
        return
      }
      token = credential
      phase = "检查本机服务"
      var request = URLRequest(
        url: serverURL.appendingPathComponent("api/auth/session"), timeoutInterval: 3)
      request.cachePolicy = .reloadIgnoringLocalCacheData
      request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
      let (data, response) = try await connectionSession.data(for: request)
      guard generation == current, connectionCheckRevision == revision, !Task.isCancelled else {
        return
      }
      guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
        throw ClientError.unavailable
      }
      if statusCode == 401 { throw ClientError.unauthorized }
      guard statusCode == 200, data.count <= 64 * 1024,
        let result = try JSONSerialization.jsonObject(with: data) as? JSON,
        let authenticated = result["authenticated"] as? Bool
      else { throw ClientError.rejected }
      guard authenticated else { throw ClientError.unauthorized }
      let recovered = !isConnected
      isConnected = true
      connectionFailure = nil
      updateConnectionStatus()
      if recovered, service != nil {
        if !hasLoadedConfiguration { resumeConfigurationRefreshes() }
        requestRefresh()
      }
    } catch {
      // 被前台唤醒替换的检查即使迟到，也不能覆盖新连接或清除新凭证。
      guard generation == current, connectionCheckRevision == revision, !Task.isCancelled else {
        return
      }
      isConnected = false
      if (error as? ClientError) == .unauthorized {
        token = ""
        rpcSession.close(error: error)
      }
      connectionFailure = Self.connectionFailureStatus(error, phase: phase)
      updateConnectionStatus()
    }
  }

  func recordRefreshResult(_ area: RefreshArea, error: Error?) {
    refreshFailures[area] = error.map {
      "\(area.rawValue)刷新失败（\(Self.failureReason($0))），正在重试"
    }
    updateConnectionStatus()
  }

  private func updateConnectionStatus() {
    let next: String
    if isConnected {
      let warning = RefreshArea.allCases.compactMap { refreshFailures[$0] }.first
      next = warning.map { "T3 Server 已连接；\($0)" } ?? "T3 Server 已连接"
    } else {
      next = connectionFailure ?? service?.status ?? "T3 Server 尚未连接"
    }
    if status != next { status = next }
  }

  func stop() {
    conversationCache.persist()
    hasLiveSkillShell = false
    skillCache.reset()
    generation = UUID()
    htmlRenderCacheScope = UUID()
    loop?.cancel()
    loop = nil
    serviceReadiness?.cancel()
    serviceReadiness = nil
    connectionLoop?.cancel()
    connectionLoop = nil
    configurationLoop?.cancel()
    configurationLoop = nil
    configurationRevision = UUID()
    configurationMaintenance?.cancel()
    configurationMaintenance = nil
    configurationMetadata?.cancel()
    configurationMetadata = nil
    rpcSession.close()
    providerCatalogs = [:]
    serverDefaultModelSelection = nil
    connectionCheckRevision = UUID()
    connectionFailure = nil
    refreshFailures.removeAll()
    service = nil
    threadRefreshes.cancelAll()
    for task in projectCreations.values { task.cancel() }
    projectCreations.removeAll()
    assetRefreshes.cancelAll()
    shellRefreshTask?.cancel()
    shellRefreshTask = nil
    shellRefreshRequested = false
    token = ""
    connectedServerURL = nil
    providers = []
    hasLoadedConfiguration = false
    configurationEnvironmentID = nil
    supportsThreadStop = false
    supportsTitleRegeneration = false
    modelContextSettings = .empty
    textGenerationModels.reset()
    syncedDefaultModelPreference = nil
    modelVisibilityRevision += 1
    isConnected = false
    status = "T3 Server 尚未连接"
    watches.removeAll()
    imageCache.removeAll()
    replyImageCache.removeAll()
    toolDetailCache.removeAll()
    toolHydrationPositions.removeAll()
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
  func thread(_ id: String) -> JSON? { threadsByID[id] }

  private func indexThreads() {
    // 保留 first(where:) 对重复 ID 的首条语义；删除或重连整体替换，不能留旧线程。
    var index: [String: JSON] = [:]
    index.reserveCapacity(threads.count)
    for thread in threads {
      if let id = thread["id"] as? String, index[id] == nil { index[id] = thread }
    }
    threadsByID = index
  }
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
      if isConnected, hasLiveSkillShell, hasLoadedConfiguration { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ClientError.unavailable
  }

  func request(_ path: String, method: String = "GET", body: JSON? = nil) async throws -> JSON {
    guard let base = service?.serverURL, !token.isEmpty else { throw ClientError.unavailable }
    let current = generation
    let credential = token
    var request = URLRequest(url: URL(string: base.absoluteString + path)!)
    request.httpMethod = method
    request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("2", forHTTPHeaderField: "x-t3-orchestration-protocol")
    if let body { request.httpBody = try await ImmutableJSONSnapshot(value: body).encode() }
    guard generation == current, !Task.isCancelled else { throw CancellationError() }
    let transport = path.hasPrefix("/api/orchestration/threads/") ? threadSession : session
    let (data, response) = try await transport.data(for: request)
    guard generation == current, service?.serverURL == base else { throw CancellationError() }
    guard let status = (response as? HTTPURLResponse)?.statusCode else {
      throw ClientError.unavailable
    }
    if status == 401 {
      guard token == credential else { throw CancellationError() }
      token = ""
      connectionCheckRevision = UUID()
      isConnected = false
      connectionFailure = Self.connectionFailureStatus(ClientError.unauthorized, phase: "校验授权")
      updateConnectionStatus()
      throw ClientError.unauthorized
    }
    guard status == 200 else { throw HTTPFailure(status: status) }
    guard data.count <= 32 * 1024 * 1024 else { throw ClientError.rejected }
    let snapshot = try await ImmutableJSONSnapshot.decode(data)
    guard generation == current, service?.serverURL == base else { throw CancellationError() }
    return snapshot.value
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

  func interrupt(threadID: String, runID: String? = nil) async throws {
    // 与官方 interruptThreadTurn 相同：优先停止整个线程，不依赖分页/缓存中的旧 run ID。
    if supportsThreadStop {
      try await dispatch(["type": "thread.stop", "threadId": threadID])
      return
    }
    var target = runID
    if target == nil {
      let snapshot = try await recoverySnapshot(threadID: threadID)
      let projection = snapshot["projection"] as? JSON
      target =
        (projection?["runs"] as? [JSON])?.last(where: {
          ["preparing", "starting", "running", "waiting"].contains($0["status"] as? String ?? "")
        })?["id"] as? String
    }
    guard let target else { throw ClientError.rejected }
    try await dispatch([
      "type": "run.interrupt", "threadId": threadID, "runId": target, "holdQueue": true,
    ])
  }

  static func mutationMethod(for type: String?) -> String {
    ["project.create", "project.update", "project.delete"].contains(type ?? "")
      ? "projects.mutate" : "orchestration.dispatchCommand"
  }

  func ensureProject(_ url: URL) async throws -> String {
    let root = url.standardizedFileURL
    let path = root.path
    if let pending = projectCreations[path] { return try await pending.value }
    let current = generation
    let task = Task<String, Error> {
      try await self.waitUntilReady()
      // 先读权威列表，避免启动缓存将已删除项目误判为存在；同目录并发请求共享本次任务。
      try await self.refreshShell()
      if let id = self.projectID(for: root) { return id }
      // 删除后的项目 ID 是服务端墓碑；新的添加操作不能复用旧身份或旧命令回执。
      let id = UUID().uuidString
      try await self.dispatch(
        [
          "type": "project.create", "projectId": id,
          "title": root.lastPathComponent, "workspaceRoot": path,
        ], refreshAfter: false)
      try await self.refreshShell()
      guard let confirmedID = self.projectID(for: root) else { throw ClientError.rejected }
      guard confirmedID == id else { throw ClientError.rejected }
      return confirmedID
    }
    projectCreations[path] = task
    defer {
      if generation == current { projectCreations.removeValue(forKey: path) }
    }
    return try await task.value
  }

  func refresh() async throws {
    try await refreshShell()
    let tasks = requestThreadRefreshes()
    // 显式刷新仍等待本次会话读取；日常轮询和命令回执只等待列表，不等图片。
    for task in tasks { try await task.value }
    try await assetRefreshes.waitForCurrent()
  }

  @discardableResult
  private func requestThreadRefreshes() -> [Task<Void, Error>] {
    Set(watches.values.map { $0.threadID }).map { id in
      threadRefreshes.request(id) { try await self.refreshThread(id) }
    }
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

  private func refreshThread(_ id: String) async throws {
    let current = generation
    guard watches.values.contains(where: { $0.threadID == id }) else { return }
    let escaped = id.addingPercentEncoding(
      withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%")))!
    let nativeDetail = try await request("/api/orchestration/threads/\(escaped)")
    guard generation == current else { return }
    // 快照含继承历史等跨线程派生数据，当前线程的事件序号不能完整代表内容。
    // 按实际载荷去重，且每个观察者独立确认，避免新订阅被旧订阅的缓存跳过。
    let fingerprint = try await ImmutableJSONSnapshot(value: nativeDetail).fingerprint()
    guard generation == current else { return }
    let observers = watches.filter {
      $0.value.threadID == id && $0.value.deliveredSnapshot != fingerprint
    }
    if observers.isEmpty { return }
    guard let base = service?.serverURL else { return }
    // 先用现有缓存发布正文、队列和交互状态；首次下载不得阻塞这些轻量更新。
    // 缓存路径复用完整水合逻辑，避免新快照使已显示的图片和工具输出闪回占位。
    let (cachedNative, cachedToolsComplete) = await hydrateToolImages(
      nativeDetail, threadID: id, base: base,
      performRPC: { try await self.rpc($0, payload: $1) },
      loadHTML: { try await self.htmlRenderDocument($0) }, cachedOnly: true)
    let cachedDetail = try await ImmutableJSONSnapshot(value: cachedNative).presentedThread().value
    guard generation == current else { return }
    if let metrics = cachedDetail["sessionStats"] as? JSON,
      let data = try? JSONSerialization.data(withJSONObject: metrics)
    {
      defaults.set(data, forKey: "t3DesktopV2Metrics.\(id)")
    }
    let (cachedReplies, cachedRepliesComplete) = await hydrateReplyImages(
      cachedDetail, threadID: id, cachedOnly: true)
    let (immediate, cachedImagesComplete) = await hydrateImages(cachedReplies, cachedOnly: true)
    let cachedComplete = cachedToolsComplete && cachedRepliesComplete && cachedImagesComplete
    let ui = T3V2Presentation.requests(nativeDetail)
    for (owner, observer) in observers where watches[owner] === observer {
      observer.receiveUI(ui)
      observer.deliver(immediate, fingerprint: fingerprint, complete: cachedComplete)
    }
    if cachedComplete { return }
    assetRefreshes.request(id) {
      await self.refreshAssets(
        nativeDetail, threadID: id, base: base, fingerprint: fingerprint, observers: observers)
    }
  }

  private func refreshAssets(
    _ nativeDetail: JSON, threadID id: String, base: URL, fingerprint: Data,
    observers: [UUID: ThreadWatch]
  ) async {
    let current = generation
    let (richNative, toolsComplete) = await hydrateToolImages(
      nativeDetail, threadID: id, base: base,
      performRPC: { try await self.rpc($0, payload: $1) },
      loadHTML: { try await self.htmlRenderDocument($0) })
    guard let detail = try? await ImmutableJSONSnapshot(value: richNative).presentedThread().value,
      generation == current
    else { return }
    let (withReplies, repliesComplete) = await hydrateReplyImages(detail, threadID: id)
    let (hydrated, complete) = await hydrateImages(withReplies)
    guard generation == current else { return }
    // 下载途中可能已经发布更新的正文；旧资源只能进入缓存，不能覆盖新快照。
    for (owner, observer) in observers where watches[owner] === observer {
      observer.deliverAssets(
        hydrated, fingerprint: fingerprint,
        complete: complete && repliesComplete && toolsComplete)
    }
  }
  // Do not invalidate the entire desktop or rewrite its cache on identical polls.
  // The first live snapshot must still be delivered when loaded from disk.
  func applyShell(_ next: JSON) {
    hasLiveSkillShell = true
    guard !hasDeliveredShell || !NSDictionary(dictionary: shell).isEqual(to: next) else { return }
    hasDeliveredShell = true
    shell = next
    indexThreads()
    reconcileSkillWorkspaces(now: Date())
    sessionCatalog.update(threads: threads)
    for event in taskStatusTracker.consume(threads) { onTaskStatus?(event) }
    if let data = try? JSONSerialization.data(withJSONObject: next) {
      defaults.set(data, forKey: "t3DesktopShellCache")
    }
    onShell?(next)
  }

  func searchSessions(query: String, sessions: [SessionItem]) async throws -> [SessionSearchResult]
  {
    let query = ServerThreadSearchQuery(query)
    guard query.canSearch else { throw ClientError.rejected }
    let current = generation
    let value = try await rpc(
      "orchestration.searchThreads", payload: ["query": query.text, "limit": 50])
    try Task.checkCancellation()
    guard current == generation else { throw CancellationError() }
    let data = try JSONSerialization.data(withJSONObject: value)
    let response = try JSONDecoder().decode(ServerThreadSearchResponse.self, from: data)
    return response.results(in: sessions)
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

  func exportSessionHTML(threadID: String) async throws -> String {
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
    let escaped = threadID.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    let result = try await request(
      "/api/orchestration/threads/\(escaped)/export-html", method: "POST", body: [:])
    guard let html = result["html"] as? String, !html.isEmpty else {
      throw ClientError.rejected
    }
    return html
  }

  func sessionControl(threadID: String, operation: String, accountName: String? = nil) async throws
  {
    try await dispatch(
      Self.sessionControlCommand(
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
    guard let service, let provider, ["openai", "openai-codex"].contains(provider)
    else { return nil }
    return try await service.accountStatus(
      threadID: threadID, provider: provider, force: force, selectionOnly: selectionOnly)
  }

  func accountControl(_ input: JSON) async throws -> JSON {
    guard let service else { throw ClientError.unavailable }
    return try await service.accountControl(input)
  }

  func requestRefresh(includeThreads: Bool = true) {
    if includeThreads { requestThreadRefreshes() }
    let current = generation
    let serverURL = connectedServerURL
    Task { [weak self] in
      guard let self, self.generation == current else { return }
      do {
        // 新建/Settle 的列表确认有独立通道，不排在任何会话的附件下载后面。
        try await self.refreshShell()
        guard self.generation == current, !Task.isCancelled else { return }
        guard self.connectedServerURL == serverURL else { return }
        self.recordRefreshResult(.shell, error: nil)
      } catch {
        // 后台读取失败由下一次轮询恢复，不重试任何写入命令。
        guard self.generation == current, !Task.isCancelled else { return }
        guard self.connectedServerURL == serverURL else { return }
        self.recordRefreshResult(.shell, error: error)
      }
    }
  }

  func syncDefaultModelPreference() async throws {
    // 没有本地偏好不等于用户要求清空 Server 默认值；相同选择也不重复写盘/触发发现。
    guard let model = defaults.string(forKey: "defaultNewSessionModelID"), !model.isEmpty else {
      return
    }
    let selection: JSON = ["instanceId": "pi", "model": model]
    if serverDefaultModelSelection?["instanceId"] as? String == "pi",
      serverDefaultModelSelection?["model"] as? String == model
    {
      return
    }
    let data = try JSONSerialization.data(withJSONObject: ["defaultModelSelection": selection])
    guard data != syncedDefaultModelPreference else { return }
    let current = generation
    let base = connectedServerURL
    _ = try await rpc(
      "server.updateSettings", payload: ["patch": ["defaultModelSelection": selection]])
    guard generation == current, base == connectedServerURL else { throw CancellationError() }
    syncedDefaultModelPreference = data
  }

  func applyModelVisibility(_ settings: JSON) throws {
    guard let preferences = settings["providerModelPreferences"] else { throw ClientError.rejected }
    let hidden: [String]
    if preferences is NSNull {
      hidden = []
    } else if let preferences = preferences as? JSON {
      if let pi = preferences["pi"] {
        guard let pi = pi as? JSON, let values = pi["hiddenModels"] as? [String] else {
          throw ClientError.rejected
        }
        hidden = values
      } else {
        hidden = []
      }
    } else {
      throw ClientError.rejected
    }
    let next = Set(hidden)
    guard next != hiddenModelIDs else { return }
    hiddenModelIDs = next
    onModelsChanged?()
  }

  func setModelVisible(_ visible: Bool, modelID: String) async throws {
    guard isConnected, !isUpdatingModelVisibility else { throw ClientError.unavailable }
    isUpdatingModelVisibility = true
    modelVisibilityRevision += 1
    let current = generation
    let revision = modelVisibilityRevision
    defer { isUpdatingModelVisibility = false }
    let settings = try await rpc(
      "server.updateSettings",
      payload: [
        "patch": ["setModelsHidden": [["provider": "pi", "model": modelID, "hidden": !visible]]]
      ])
    guard generation == current, revision == modelVisibilityRevision else {
      throw ClientError.unavailable
    }
    modelVisibilityRevision += 1
    try applyModelVisibility(settings)
    await updateTextGenerationModel(nil)
  }

  func updateTextGenerationModel(_ modelID: String?) async {
    await textGenerationModels.update(refresh: modelID == nil) { [self] in
      guard let service else { throw ClientError.unavailable }
      return try await service.textGenerationModelSettings(modelID: modelID)
    }
  }

  // 仅供用户主动刷新目录；日常启动/更新使用常驻配置订阅，不再轮询 getConfig。
  func loadConfig() async throws {
    let current = generation
    let revision = modelVisibilityRevision
    let config = try await rpc("server.getConfig")
    guard generation == current, revision == modelVisibilityRevision else {
      throw CancellationError()
    }
    try applyConfigurationEvent(["version": 1, "type": "snapshot", "config": config])
  }

  func applyConfigurationEvent(_ event: JSON) throws {
    guard event["version"] as? Int == 1, let type = event["type"] as? String else {
      throw ClientError.rejected
    }
    switch type {
    case "snapshot":
      guard let config = event["config"] as? JSON,
        let settings = config["settings"] as? JSON,
        let values = config["providers"] as? [JSON],
        let environment = config["environment"] as? JSON,
        let capabilities = environment["capabilities"] as? JSON
      else { throw ClientError.rejected }
      try applyModelVisibility(settings)
      serverDefaultModelSelection = settings["defaultModelSelection"] as? JSON
      configurationEnvironmentID = environment["environmentId"] as? String
      supportsThreadStop = capabilities["threadStop"] as? Bool == true
      supportsTitleRegeneration = capabilities["threadTitleRegeneration"] as? Bool == true
      applyProviderCatalog(values, modelCatalogs: providerCatalogs)
      hasLoadedConfiguration = true
      recordRefreshResult(.configuration, error: nil)
      refreshConfigurationMetadata()
    case "settingsUpdated":
      guard hasLoadedConfiguration, let payload = event["payload"] as? JSON,
        let settings = payload["settings"] as? JSON
      else { throw ClientError.rejected }
      try applyModelVisibility(settings)
      serverDefaultModelSelection = settings["defaultModelSelection"] as? JSON
    case "providerStatuses":
      guard hasLoadedConfiguration, let payload = event["payload"] as? JSON,
        let values = payload["providers"] as? [JSON]
      else { throw ClientError.rejected }
      applyProviderCatalog(values, modelCatalogs: providerCatalogs)
    case "keybindingsUpdated", "environmentThemesUpdated", "usageLimitSourcesUpdated":
      break  // 当前原生视图不消费这些官方事件；不能把合法扩展事件当作连接失败。
    default: throw ClientError.rejected
    }
  }

  private func refreshConfigurationMetadata() {
    configurationMetadata?.cancel()
    let current = generation
    let base = connectedServerURL
    configurationMetadata = Task { [weak self] in
      while let self, let service = self.service, !Task.isCancelled, self.generation == current {
        do {
          // 原始目录用于模型显隐设置，宿主额外元数据不能再阻塞官方配置快照的可用性。
          let catalogs = try await service.modelCatalog()
          let context = try await service.modelContextSettings()
          guard self.generation == current, self.connectedServerURL == base, !Task.isCancelled
          else {
            return
          }
          self.providerCatalogs = catalogs
          self.modelContextSettings = context
          self.applyProviderCatalog(self.providers, modelCatalogs: catalogs)
          await self.updateTextGenerationModel(nil)
          guard self.generation == current, self.connectedServerURL == base, !Task.isCancelled
          else {
            return
          }
          self.recordRefreshResult(.modelMetadata, error: nil)
          return
        } catch {
          guard self.generation == current, self.connectedServerURL == base, !Task.isCancelled
          else {
            return
          }
          self.recordRefreshResult(.modelMetadata, error: error)
          try? await Task.sleep(for: .seconds(2))
        }
      }
    }
  }

  func applyProviderCatalog(_ values: [JSON], modelCatalogs: [String: [JSON]]) {
    providers = values.map { provider in
      var nativeProvider = provider
      if let id = provider["instanceId"] as? String, let models = modelCatalogs[id] {
        // 订阅是可见目录的事实来源。额外目录只补回被隐藏的模型，不能用旧缓存
        // 覆盖实时模型能力、重新加入已移除模型，或让新模型等到下一次手动刷新。
        let live = provider["models"] as? [JSON] ?? []
        let slugs = Set(live.compactMap { $0["slug"] as? String })
        let hidden = id == "pi" ? hiddenModelIDs : []
        nativeProvider["models"] =
          live
          + models.filter {
            guard let slug = $0["slug"] as? String else { return false }
            return hidden.contains(slug) && !slugs.contains(slug)
          }
      }
      return nativeProvider
    }
    onModelsChanged?()
  }
  func didCompletePoll() {
    if !isConnected { isConnected = true }
    reconcileSkillWorkspaces(now: Date())
  }

  func enterSkillWorkspace(owner: UUID, context: WorkspaceSkillContext) {
    skillInterests[owner] = context
    reconcileSkillWorkspaces(now: Date())
  }

  func leaveSkillWorkspace(owner: UUID) { skillInterests.removeValue(forKey: owner) }

  func skillKey(for context: WorkspaceSkillContext) -> WorkspaceSkillCache.Key? {
    let cwd: String
    if let id = context.threadID {
      // 磁盘 shell 和尚未解析的目标线程不能暂时回退到项目根目录。
      guard hasLiveSkillShell, let thread = thread(id) else { return nil }
      let worktree = thread["worktreePath"] as? String ?? ""
      cwd = worktree.isEmpty ? context.projectCwd : worktree
    } else {
      cwd = context.projectCwd
    }
    return .init(
      instanceID: context.instanceID, cwd: URL(fileURLWithPath: cwd).standardizedFileURL.path)
  }

  private func reconcileSkillWorkspaces(now: Date) {
    guard isConnected, hasLiveSkillShell else { return }
    for key in Set(skillInterests.values.compactMap { skillKey(for: $0) }) {
      preloadWorkspaceSkills(key: key, reload: .ifStale, now: now)
    }
  }

  func reloadWorkspaceSkills(key: WorkspaceSkillCache.Key) {
    guard isConnected, hasLiveSkillShell else { return }
    preloadWorkspaceSkills(key: key, reload: .force, now: Date())
  }

  private func preloadWorkspaceSkills(
    key: WorkspaceSkillCache.Key, reload: WorkspaceSkillCache.Reload, now: Date
  ) {
    let fresh = reload == .force || skillCache.state(for: key).success != nil
    skillCache.preload(key: key, reload: reload, now: now) { [self] in
      if let skillDiscovery { return try await skillDiscovery(key, fresh) }
      return try await discoverWorkspaceSkills(key: key, fresh: fresh)
    }
  }

  /// 工作区快照是 skills 的唯一来源，不能用机器级目录替代项目级发现结果。
  func discoverWorkspaceSkills(key: WorkspaceSkillCache.Key, fresh: Bool) async throws
    -> WorkspaceSkillCache.Success
  {
    let instanceID = key.instanceID
    let cwd = key.cwd
    struct Provider: Decodable {
      let instanceId: String
      let workspaceSnapshots: [SkillWorkspaceSnapshot]?
    }
    struct Updated: Decodable { let providers: [Provider] }
    func snapshot(in values: [JSON]) throws -> SkillWorkspaceSnapshot? {
      let data = try JSONSerialization.data(withJSONObject: ["providers": values])
      let decoded = try JSONDecoder().decode(Updated.self, from: data)
      return decoded.providers.first { $0.instanceId == instanceID }?
        .workspaceSnapshots?.first { $0.cwd == cwd }
    }
    if !fresh, let cached = try snapshot(in: providers), cached.isCurrent(at: Date()),
      let checkedAt = cached.validationDate
    {
      return .init(skills: cached.skills, validatedAt: checkedAt)
    }
    let result = try await rpc(
      "server.refreshProviders",
      payload: ["instanceId": instanceID, "cwd": cwd, "fresh": fresh], timeoutSeconds: 60)
    guard let updated = result["providers"] as? [JSON],
      let scoped = try snapshot(in: updated), scoped.isCurrent(at: Date()),
      let checkedAt = scoped.validationDate
    else { throw ClientError.rejected }
    return .init(skills: scoped.skills, validatedAt: checkedAt)
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

  func browserPreviewSessions(threadID: String) async throws -> [T3BrowserTab] {
    let result = try await rpc("preview.list", payload: ["threadId": threadID])
    return try T3BrowserTab.read(result)
  }

  func updateBrowserPreviewTab(threadID: String, closing tabID: String?) async throws {
    if let tabID {
      _ = try await rpc("preview.close", payload: ["threadId": threadID, "tabId": tabID])
    } else {
      _ = try await rpc(
        "preview.open",
        payload: [
          "threadId": threadID, "runtime": "server", "reveal": true,
        ], timeoutSeconds: 90)
    }
  }

  /// 允许上游原生交互；是否能操作及控制权归属均由 Server 的 control 通知决定。
  func browserPreviewSocket(threadID: String, tabID: String) async throws
    -> URLSessionWebSocketTask
  {
    let ticket = try await request("/api/auth/websocket-ticket", method: "POST", body: [:])
    guard let secret = ticket["ticket"] as? String, let base = service?.serverURL,
      var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
    else { throw ClientError.unavailable }
    components.scheme = base.scheme == "https" ? "wss" : "ws"
    components.path = "/api/preview-stream/ws"
    components.queryItems = [
      .init(name: "wsTicket", value: secret), .init(name: "threadId", value: threadID),
      .init(name: "tabId", value: tabID), .init(name: "interactive", value: "true"),
      .init(name: "maxWidth", value: "2560"), .init(name: "maxHeight", value: "1600"),
      .init(name: "quality", value: "80"),
    ]
    guard let url = components.url else { throw ClientError.rejected }
    let socket = session.webSocketTask(with: url)
    socket.maximumMessageSize = 8 * 1024 * 1024
    socket.resume()
    return socket
  }

  private func rpc(
    _ method: String, payload: JSON = [:], timeoutSeconds: Int = 15,
    receive: ((JSON) -> Void)? = nil
  ) async throws -> JSON {
    let current = generation
    let base = service?.serverURL
    guard base != nil else { throw ClientError.unavailable }
    let result = try await rpcSession.call(
      method, payload: payload, timeout: .seconds(timeoutSeconds), receive: receive)
    guard generation == current, service?.serverURL == base, !Task.isCancelled else {
      throw CancellationError()
    }
    return result
  }

  /// Timeline snapshots omit tool output. Hydrate text and media through official
  /// detail reads, keyed by revision so running output does not become stale.
  func hydrateToolImages(
    _ native: JSON, threadID: String, base: URL,
    performRPC: (String, JSON) async throws -> JSON,
    loadHTML: (T3HTMLRender) async throws -> String,
    cachedOnly: Bool = false
  ) async -> (JSON, Bool) {
    var native = native
    guard var projection = native["projection"] as? JSON,
      var rows = projection["visibleTurnItems"] as? [JSON]
    else { return (native, true) }
    let current = generation
    var complete = true
    var reads = 0
    var downloads = 0
    let scope = "\(base.absoluteString)|\(threadID)"
    // 轮询中的 revision 会持续变化，续读位置必须绑定稳定的条目及其所属会话。
    let start =
      toolHydrationPositions[scope].flatMap { position in
        rows.firstIndex { row in
          guard let item = row["item"] as? JSON else { return false }
          return item["id"] as? String == position.itemID
            && (item["threadId"] as? String ?? threadID) == position.ownerThreadID
        }
      }.map { ($0 + 1) % rows.count } ?? 0
    let indices = Array(rows.indices.dropFirst(start)) + Array(rows.indices.prefix(start))
    itemLoop: for index in indices {
      guard var item = rows[index]["item"] as? JSON,
        (item["type"] as? String == "dynamic_tool"
          && (!T3V2Presentation.active.contains(item["status"] as? String ?? "")
            || item["outputOmitted"] as? Bool == true))
          || (item["type"] as? String == "command_execution"
            && item["outputOmitted"] as? Bool == true),
        let id = item["id"] as? String, let revision = item["updatedAt"] as? String
      else { continue }
      let ownerThreadID = item["threadId"] as? String ?? threadID
      let key = "\(base.absoluteString)|\(ownerThreadID)|\(id)|\(revision)"
      if let cached = toolDetailCache[key] {
        // 同一 revision 的重试沿用完整详情，避免仅保留 HTML 引用而丢失已取回的 output。
        item = cached
        rows[index]["item"] = cached
        guard let retryAfter = htmlRetryAfter[key] else { continue }
        if retryAfter > Date() {
          complete = false
          continue
        }
      }
      guard !cachedOnly, reads < 8 else {
        complete = false
        continue
      }
      reads += 1
      toolHydrationPositions[scope] = ToolHydrationPosition(
        ownerThreadID: ownerThreadID, itemID: id)
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
        // 已标记省略的输出必须从详情取回，不能把读取失败缓存成合法空输出。
        if item["outputOmitted"] as? Bool == true,
          detail["output"] == nil || detail["output"] is NSNull
        {
          throw ClientError.rejected
        }
        item["output"] = detail["output"]
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
        if isHTML || item["outputOmitted"] as? Bool == true {
          // 详情失败不能提交 revision，否则当前打开会话永远不会恢复。
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
  private func hydrateReplyImages(
    _ detail: JSON, threadID: String, cachedOnly: Bool = false
  ) async -> (JSON, Bool) {
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
        guard !cachedOnly, downloads < 8 else {
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
    let namespace = service?.assetCacheNamespace ?? base.absoluteString
    let key = "\(namespace)|\(reference.attachmentID)"
    let html = try await T3HTMLDocumentCache.shared.document(key: key) { @MainActor [self] in
      guard generation == current else { throw CancellationError() }
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
      let data = try await BoundedAssetDownload.data(
        from: url, session: assetSession, limit: T3HTMLDocumentCache.maxDocumentBytes,
        mimeType: "text/html")
      guard generation == current else { throw CancellationError() }
      guard let html = String(data: data, encoding: .utf8), !html.isEmpty
      else { throw ClientError.rejected }
      return html
    }
    guard generation == current, !Task.isCancelled else { throw CancellationError() }
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
    let data = try await BoundedAssetDownload.data(
      from: url, session: assetSession, limit: T3ToolImageCache.maxBytes, mimeType: mime)
    guard generation == current else { throw CancellationError() }
    let attachment = try await Task.detached(priority: .utility) {
      try T3ToolImageCache.store(data, key: key, mimeType: mime)
    }.value
    guard generation == current else { throw CancellationError() }
    return attachment
  }

  private func hydrateImages(_ detail: JSON, cachedOnly: Bool = false) async -> (JSON, Bool) {
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
        guard !cachedOnly, downloads < 8 else {
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
    if let cached = await Task.detached(
      priority: .utility,
      operation: {
        T3ToolImageCache.cached(key: cacheKey, mimeType: mime, size: size)
      }
    ).value {
      return cached
    }
    let signed = try await rpc(
      "assets.createUrl", payload: ["resource": ["_tag": "attachment", "attachmentId": id]])
    guard let relative = signed["relativeUrl"] as? String, relative.hasPrefix("/api/assets/"),
      let url = URL(string: base.absoluteString + relative), url.host == base.host,
      url.port == base.port
    else { throw ClientError.rejected }
    let current = generation
    let data = try await BoundedAssetDownload.data(
      from: url, session: assetSession, limit: size, mimeType: nil)
    guard generation == current, data.count == size else { throw ClientError.rejected }
    let attachment = try await Task.detached(priority: .utility) {
      try T3ToolImageCache.store(data, key: cacheKey, mimeType: mime)
    }.value
    guard generation == current else { throw CancellationError() }
    return attachment
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
  // Use only fixed categories, never server error bodies, URLs or credentials.
  static func connectionFailureStatus(_ error: Error, phase: String) -> String {
    "T3 Server 连接失败（\(phase)：\(failureReason(error))）；正在重试，命令不会自动重发。"
  }

  private static func failureReason(_ error: Error) -> String {
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
    return reason
  }

  /// 只接受本次已认证连接取得的配置与列表；磁盘缓存永远不能授权首次投递。
  func liveDeliveryEnvironmentID(threadID: String, project: URL) -> String? {
    guard isConnected, hasLiveSkillShell, hasLoadedConfiguration,
      let id = configurationEnvironmentID, !id.isEmpty,
      let projectID = projectID(for: project),
      thread(threadID)?["projectId"] as? String == projectID
    else { return nil }
    return id
  }

  func recoveryEnvironmentID() async throws -> String {
    if isConnected, hasLoadedConfiguration, let id = configurationEnvironmentID, !id.isEmpty {
      return id
    }
    let config = try await rpc("server.getConfig")
    guard let environment = config["environment"] as? JSON,
      let id = environment["environmentId"] as? String, !id.isEmpty
    else { throw ClientError.rejected }
    return id
  }

  func recoveryProjectID(_ url: URL) async throws -> String? {
    try await refreshShell()
    return projectID(for: url)
  }

  func recoverySnapshot(threadID: String) async throws -> JSON {
    let escaped = threadID.addingPercentEncoding(
      withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%")))!
    return try await request("/api/orchestration/threads/\(escaped)")
  }

  struct HTTPFailure: Error, Sendable { let status: Int }

  struct RPCFailure: LocalizedError, Sendable {
    let tags: [String]
    var threadMissing: Bool { tags.contains("ProjectionStoreThreadNotFoundError") }

    init(exit: JSON) {
      // 仅提取有界的类型标签；原始错误可能带正文、路径或凭据，不能直接展示/持久化。
      var result: [String] = []
      var remaining = 256
      func visit(_ value: Any, depth: Int) {
        guard depth < 16, remaining > 0 else { return }
        remaining -= 1
        if let object = value as? JSON {
          // Schema.Defect 将 Error 的 _tag 编码为 name，普通 TaggedError 保留 _tag。
          if let tag = object["_tag"] as? String ?? object["name"] as? String,
            tag.range(of: "^[A-Za-z][A-Za-z0-9]{0,95}$", options: .regularExpression) != nil,
            !result.contains(tag)
          {
            result.append(tag)
          }
          for key in object.keys.sorted() { visit(object[key]!, depth: depth + 1) }
        } else if let values = value as? [Any] {
          for value in values { visit(value, depth: depth + 1) }
        }
      }
      visit(exit, depth: 0)
      tags = result
    }

    var errorDescription: String? {
      if threadMissing { return "Server 找不到原会话；原稿和附件已保留，可检查后迁移" }
      if tags.contains("OrchestratorCommandPreviouslyRejectedError") {
        return "Server 已拒绝原命令；可取回原稿修正后重新提交，或导出保存"
      }
      return "Server 拒绝提交；原稿已保留，请检查授权、模型和会话后恢复"
    }
  }

  enum ClientError: Error { case unavailable, unauthorized, rejected }
}

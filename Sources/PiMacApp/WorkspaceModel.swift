import Combine
import Foundation

struct WorkspaceProject: Identifiable, Hashable {
  let url: URL
  var id: String { url.standardizedFileURL.path }
  var customName: String? = nil
  var name: String {
    let title = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return title.isEmpty ? url.lastPathComponent : title
  }
}

/// Desktop workspace is a projection of T3 state plus local selection/drafts.
@MainActor
final class WorkspaceModel: ObservableObject {
  struct Tab: Identifiable {
    let id: UUID
    let model: AppModel
    var requestedSessionPath: String?
    var createdAt: Date
    var isDraft: Bool
  }
  @Published private(set) var tabs: [Tab] = []
  @Published private(set) var projects: [WorkspaceProject] = []
  @Published private(set) var loadingSessionCatalogs: Set<String> = []
  @Published private(set) var submittingTitleRegenerations: Set<String> = []
  @Published var selectedTabID: UUID?
  @Published private(set) var projectFilterPath: String?

  /// Sidebar selection filters the catalog; it never changes the active conversation.
  func toggleProjectFilter(_ project: WorkspaceProject) {
    projectFilterPath = projectFilterPath == project.id ? nil : project.id
  }

  func clearProjectFilter() { projectFilterPath = nil }

  var filteredSessions: [SessionItem] { filteredSessions(settled: false) }

  func filteredSessions(settled: Bool) -> [SessionItem] {
    let projectID = projectFilterPath.flatMap {
      server.projectID(for: URL(fileURLWithPath: $0))
    }
    let catalog =
      projectFilterPath != nil && projectID == nil
      ? [] : server.sessions(projectID: projectID, settled: settled)
    let sessions = catalog.filter {
      !pendingSettlementPaths.contains($0.path)
    }
    guard !settled else { return sessions }
    // shell 到达后按线程身份自然交接；旧 shell 不能吞掉刚点击发送的会话。
    var seen: Set<String> = []
    let local = deliveries.store.messages.compactMap { record -> SessionItem? in
      let path = "t3:\(record.threadID)"
      guard record.isVisible, server.thread(record.threadID) == nil,
        !pendingSettlementPaths.contains(path),
        projectFilterPath == nil || record.projectPath == projectFilterPath,
        seen.insert(path).inserted
      else { return nil }
      return SessionItem(
        path: path, title: String(record.text.prefix(60)), modifiedAt: record.createdAt)
    }.sorted { $0.modifiedAt > $1.modifiedAt }
    return local + sessions
  }

  func project(forSessionPath path: String) -> WorkspaceProject? {
    if let id = AppModel.threadID(from: path),
      let record = deliveries.store.messages.first(where: { $0.threadID == id && $0.isVisible })
    {
      return WorkspaceProject(url: URL(fileURLWithPath: record.projectPath))
    }
    if let model = tabs.first(where: { $0.model.locallySubmittedSession?.path == path })?.model,
      let url = model.projectURL
    {
      return projects.first { $0.url == url } ?? WorkspaceProject(url: url)
    }
    guard let id = AppModel.threadID(from: path),
      let projectID = server.thread(id)?["projectId"] as? String,
      let project = server.projects.first(where: { $0["id"] as? String == projectID }),
      let root = project["workspaceRoot"] as? String
    else { return nil }
    return WorkspaceProject(
      url: URL(fileURLWithPath: root), customName: project["title"] as? String)
  }

  func switchNewChatProject(to project: WorkspaceProject) {
    guard let previous = selectedModel, !previous.hasUserMessage, !previous.isBusy,
      !previous.isLoadingConfiguration, previous.queuedPrompts.isEmpty,
      previous.projectURL?.standardizedFileURL != project.url.standardizedFileURL
    else { return }
    let text = previous.composerText
    let attachments = previous.attachments
    newSession(in: project.url)
    guard let next = selectedModel, next !== previous else { return }
    next.composerText = text
    next.attachments = attachments
    previous.composerText = ""
    previous.attachments = []
  }
  @Published var developmentReloadStatus = ""
  let extensionUI = ExtensionUIModel()
  let telegram: TelegramControl
  let t3Bridge = T3BridgeService()
  let server: T3DesktopClient
  let git = GitWorkspaceStore()
  let temporaryFiles: TemporaryFilesStore

  var selectedGitDirectory: String? {
    if let id = selectedModel?.threadID {
      guard let thread = server.thread(id) else { return nil }
      if let path = thread["worktreePath"] as? String, !path.isEmpty { return path }
    }
    return selectedModel?.projectURL?.path
  }
  private var observations: [UUID: AnyCancellable] = [:]
  private var gitObservation: AnyCancellable?
  private var draftObservations: [UUID: AnyCancellable] = [:]
  private var remoteSubmissionHolds: Set<ObjectIdentifier> = []
  private let persistsState: Bool
  private let draftDefaults: UserDefaults?
  let deliveries: MessageRecoveryCoordinator
  private var deliveryObservation: AnyCancellable?
  private var shellLoaded = false
  private var pendingCompletionVisits: Set<String> = []
  @Published private(set) var sessionCatalogRevision = 0
  private var projectImportTask: Task<Void, Never>?

  init(
    telegram: TelegramControl? = nil, restoreUserState: Bool = true,
    server client: T3DesktopClient? = nil, draftDefaults: UserDefaults? = nil,
    outboxDirectory: URL? = nil
  ) {
    let server = client ?? T3DesktopClient()
    self.server = server
    let directory =
      outboxDirectory
      ?? (restoreUserState
        ? URL.applicationSupportDirectory.appendingPathComponent("PiMac/MessageOutbox") : nil)
    deliveries = MessageRecoveryCoordinator(
      store: MessageOutboxStore(directory: directory), transport: server)
    temporaryFiles = TemporaryFilesStore(defaults: restoreUserState ? .standard : nil)
    self.telegram = telegram ?? TelegramControl()
    persistsState = restoreUserState
    self.draftDefaults = draftDefaults ?? (restoreUserState ? .standard : nil)
    gitObservation = git.$busy.removeDuplicates().dropFirst().sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    addTab(model: AppModel(restoreLastProjectOnLaunch: false), path: nil, draft: false)
    deliveryObservation = deliveries.store.$messages.combineLatest(deliveries.store.$failure)
      .sink { [weak self] _, _ in self?.objectWillChange.send() }
    server.onShell = { [weak self] snapshot in self?.applyShell(snapshot) }
    server.onModelsChanged = { [weak self] in
      guard let self else { return }
      for tab in self.tabs { tab.model.refreshModels() }
    }
    server.onAccountPoll = { [weak self] in
      guard let self else { return }
      for tab in self.tabs { tab.model.refreshCodexAccounts() }
    }
    guard restoreUserState else { return }
    server.onTaskStatus = { TaskStatusNotifications.shared.deliver($0) }
    // Cached shell is presentation only; all commands still require live readiness.
    if !server.shell.isEmpty { applyShell(server.shell) }
    server.start(service: t3Bridge)
    do { try t3Bridge.start(workspace: self, token: T3NetworkEndpoint.secret()) } catch {
      selectedModel?.statusText = "本机 T3 Server 无法启动，请检查 Node 和服务资源。"
    }
    // Import known project roots only. Historical JSONL files are never opened
    // by the desktop or silently assigned to another Provider-owned session.
    let defaults = UserDefaults.standard
    let oldPaths = Self.legacyProjectPaths(defaults: defaults)
    projectImportTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.server.waitUntilReady()
        for path in oldPaths where FileManager.default.fileExists(atPath: path) {
          _ = try await self.server.ensureProject(URL(fileURLWithPath: path))
        }
        // 迁移只做一次；保留旧偏好作历史记录，但不能在每次启动时复活已移除的项目。
        defaults.set(true, forKey: "t3ProjectImportCompleted")
        self.server.requestRefresh()
      } catch { self.selectedModel?.statusText = "项目同步未完成；原项目和历史文件均未修改。" }
    }
    self.telegram.start(workspace: self)
  }

  static func legacyProjectPaths(defaults: UserDefaults) -> [String] {
    guard !defaults.bool(forKey: "t3ProjectImportCompleted") else { return [] }
    return defaults.stringArray(forKey: "workspaceProjectPaths")
      ?? defaults.string(forKey: "lastProjectPath").map { [$0] } ?? []
  }

  var selectedModel: AppModel? { tabs.first { $0.id == selectedTabID }?.model }
  var selectedProject: WorkspaceProject? {
    selectedModel?.projectURL.map { url in
      projects.first { $0.id == url.standardizedFileURL.path } ?? WorkspaceProject(url: url)
    }
  }
  var restartBlockers: [String] {
    var reasons: [String] = []
    if persistsState && !server.isConnected { reasons.append("Server 未连接，无法确认空闲") }
    if server.hasRunningThread { reasons.append("Server 有运行中的线程") }
    if git.busy { reasons.append("Git 操作进行中") }
    if temporaryFiles.isRunning { reasons.append("临时文件整理进行中") }
    if tabs.contains(where: { $0.model.browserPreview.control.isControlling }) {
      reasons.append("浏览器正在由用户操作")
    }
    if isSettlingIdleSessions || !pendingSettlementPaths.isEmpty { reasons.append("后台 Settle 进行中") }
    if !submittingTitleRegenerations.isEmpty
      || server.threads.contains(where: { $0["titleRegeneration"] is [String: Any] })
    {
      reasons.append("会话标题重新生成中")
    }
    if !remoteSubmissionHolds.isEmpty { reasons.append("远程消息正在提交") }
    if !telegram.canRestartSafely { reasons.append("Telegram 有任务、队列或待发送回复") }
    if tabs.contains(where: { !$0.model.canRestartSafely }) { reasons.append("桌面有任务、排队消息或未确认操作") }
    if t3Bridge.managementBusy || t3Bridge.connectBusy
      || t3Bridge.connectStatus?.loginPending == true
    {
      reasons.append("设备管理或账号授权进行中")
    }
    return reasons
  }
  var canRestartSafely: Bool { restartBlockers.isEmpty }
  private func applyShell(_ snapshot: [String: Any]) {
    // Read receipts can change without a title/date/catalog revision.
    objectWillChange.send()
    pendingSettlementPaths = pendingSettlementPaths.filter { path in
      guard let id = AppModel.threadID(from: path), let thread = server.thread(id) else {
        return false
      }
      return !Self.isSettled(thread)
    }
    let nextProjects = (snapshot["projects"] as? [[String: Any]] ?? []).compactMap {
      project -> WorkspaceProject? in
      guard let root = project["workspaceRoot"] as? String else { return nil }
      return WorkspaceProject(
        url: URL(fileURLWithPath: root), customName: project["title"] as? String)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    let removedProjects = projects.filter { old in !nextProjects.contains { $0.id == old.id } }
    if projects != nextProjects { projects = nextProjects }
    // 同步其他客户端的删除，也要释放本地标签，避免新聊天重新指向已删除目录。
    for project in removedProjects { removeTabs(project: project.url) }
    if let path = projectFilterPath, !projects.contains(where: { $0.id == path }) {
      clearProjectFilter()
    }
    if sessionCatalogRevision != server.sessionCatalogRevision {
      sessionCatalogRevision = server.sessionCatalogRevision
    }
    for tab in tabs {
      tab.model.refreshCodexAccounts()
      if let project = tab.model.projectURL { tab.model.updateCatalog(sessions(in: project)) }
      if let id = tab.model.threadID, server.thread(id) == nil, !tab.model.isLoadingConfiguration,
        tab.model.locallySubmittedSession == nil
      {
        tab.model.statusText = "此线程已归档或移除，请从 Server 列表重新选择。"
      }
    }
    if !shellLoaded, !projects.isEmpty {
      shellLoaded = true
      let path = UserDefaults.standard.string(forKey: "t3SelectedProject")
      if selectedModel?.projectURL == nil {
        selectProject(projects.first { $0.id == path } ?? projects[0])
      }
    }
    acknowledgeSelectedCompletion()
  }

  /// 只确认当前可见的完成版本，不能用请求执行时间覆盖之后的新一轮结果。
  static func completionVisit(thread: [String: Any], selectedThreadID: String?) -> [String: Any]? {
    guard let id = thread["id"] as? String, id == selectedThreadID,
      T3V2Presentation.hasUnreadCompletion(thread),
      let completedAt = thread["latestRunCompletedAt"] as? String
    else { return nil }
    return ["type": "thread.visit", "threadId": id, "visitedAt": completedAt]
  }

  private func acknowledgeSelectedCompletion() {
    guard server.isConnected, let id = selectedModel?.threadID,
      let thread = server.thread(id),
      let command = Self.completionVisit(thread: thread, selectedThreadID: id),
      let completedAt = command["visitedAt"] as? String
    else { return }
    let key = "\(id)|\(completedAt)"
    // 多次 shell 推送可能先于回执返回；同一完成版本只保留一个在途请求。
    guard pendingCompletionVisits.insert(key).inserted else { return }
    Task {
      defer { pendingCompletionVisits.remove(key) }
      do {
        try await server.dispatch(command)
      } catch {
        model(forSessionPath: "t3:\(id)")?.statusText = "已读状态同步未确认，后续刷新将重试。"
      }
    }
  }

  func addProject(_ projectURL: URL) {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      selectedModel?.statusText = "添加项目失败：请选择存在的文件夹。"
      return
    }
    Task {
      do {
        _ = try await server.ensureProject(projectURL)
        try await server.refreshShell()
        selectProject(WorkspaceProject(url: projectURL))
      } catch { selectedModel?.statusText = "添加项目未确认，请刷新 Server 列表。" }
    }
  }
  func selectProject(_ project: WorkspaceProject) {
    if let tab = tabs.last(where: {
      $0.model.projectURL?.standardizedFileURL == project.url.standardizedFileURL
    }) {
      selectTab(tab.id)
      return
    }
    let saved = UserDefaults.standard.string(forKey: "t3SelectedThread.\(project.id)")
    let catalog = sessions(in: project.url)
    if let path = saved, catalog.contains(where: { $0.path == path }) {
      openSession(path: path, in: project.url)
    } else if let recent = catalog.first {
      openSession(path: recent.path, in: project.url)
    } else {
      newSession(in: project.url)
    }
  }
  func renameProject(_ project: WorkspaceProject, to name: String) {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, let id = server.projectID(for: project.url) else { return }
    Task {
      do {
        try await server.dispatch(["type": "project.update", "projectId": id, "title": title])
        try await server.refreshShell()
      } catch { selectedModel?.statusText = "项目重命名未确认，请刷新 Server 状态。" }
    }
  }

  func removeProject(_ project: WorkspaceProject) {
    guard let id = server.projectID(for: project.url) else { return }
    // 忙碌限制由 Server 原子校验，不能用可能过期的本地快照静默忽略移除操作。
    Task {
      do {
        try await server.dispatch(["type": "project.delete", "projectId": id, "force": true])
        removeTabs(project: project.url)
        if persistsState {
          let defaults = UserDefaults.standard
          defaults.removeObject(forKey: "t3SelectedThread.\(project.id)")
          if defaults.string(forKey: "t3SelectedProject") == project.id {
            defaults.removeObject(forKey: "t3SelectedProject")
          }
        }
        try await server.refreshShell()
      } catch { selectedModel?.statusText = "移除项目未确认；请检查是否有运行中任务，并刷新 Server 状态。" }
    }
  }
  /// 新聊天优先使用侧栏筛选项目；筛选本身不切换或修改当前会话。
  func newSessionInLastProject() {
    if let path = projectFilterPath {
      newSession(in: URL(fileURLWithPath: path))
      return
    }
    let savedPath = persistsState ? UserDefaults.standard.string(forKey: "t3SelectedProject") : nil
    guard
      let project = selectedProject
        ?? projects.first(where: { $0.id == savedPath })
        ?? projects.first
    else { return }
    newSession(in: project.url)
  }

  func newSession(in projectURL: URL) {
    // 未发送的本地草稿跨标签复用；旧版本遗留的空线程仍可安全复用，避免继续累积。
    let reusablePath = server.projectID(for: projectURL).flatMap {
      Self.latestEmptySessionPath(threads: server.threads, projectID: $0)
    }
    if let tab = tabs.last(where: {
      $0.isDraft && $0.model.projectURL?.standardizedFileURL == projectURL.standardizedFileURL
        && ($0.model.currentSessionPath.isEmpty || $0.model.currentSessionPath == reusablePath
          || $0.model.threadID.map({ server.thread($0) == nil }) == true)
        && !$0.model.hasUserMessage && !$0.model.isBusy && $0.model.queuedPrompts.isEmpty
    }) {
      selectTab(tab.id)
      return
    }
    let savedProjectDraft = Self.draftKey(sessionPath: nil, projectURL: projectURL).flatMap {
      draftDefaults?.object(forKey: $0)
    }
    if let path = reusablePath, savedProjectDraft == nil,
      model(forSessionPath: path).map({
        !$0.hasUserMessage && !$0.hasUnsubmittedInput && !$0.isBusy && $0.queuedPrompts.isEmpty
      }) ?? true
    {
      openSession(path: path, in: projectURL)
      return
    }
    let model = AppModel(startupProjectURL: projectURL, continueLastSession: false)
    addTab(model: model, path: nil, draft: true)
  }
  func openSession(path: String, in projectURL: URL) {
    // 首次发送先发布本地身份，Server shell 可能尚未包含该线程。
    // 优先恢复同项目的原标签，保留在途提交和未确认消息，不重连或重发。
    if let tab = tabs.first(where: {
      ($0.model.currentSessionPath == path
        || ($0.model.currentSessionPath.isEmpty && $0.requestedSessionPath == path))
        && $0.model.projectURL?.standardizedFileURL == projectURL.standardizedFileURL
    }) {
      selectTab(tab.id)
      return
    }
    guard let id = AppModel.threadID(from: path),
      server.thread(id)?["projectId"] as? String == server.projectID(for: projectURL)
        && server.thread(id) != nil
        || deliveries.store.messages.contains(where: {
          $0.threadID == id && $0.projectPath == projectURL.standardizedFileURL.path && $0.isVisible
        })
    else {
      selectedModel?.statusText = "此历史路径尚未导入 T3；不会启动旧桌面 Pi 进程。"
      return
    }
    addTab(
      model: AppModel(startupProjectURL: projectURL, startupSessionPath: path), path: path,
      draft: false)
  }
  func replaceProject(with projectURL: URL) { addProject(projectURL) }
  func remoteSessionChanged(in projectURL: URL?, sessionPath: String) { server.requestRefresh() }
  func remoteSessionUpdated(from source: AppModel) { server.requestRefresh() }
  func isLoadingSessions(in projectURL: URL) -> Bool { !server.isConnected }
  func sessions(in projectURL: URL) -> [SessionItem] {
    guard let project = server.projectID(for: projectURL) else { return [] }
    return server.sessions(projectID: project)
  }

  /// Only the leading chat is reusable; an older empty chat must not replace a
  /// new task after the latest chat has already been used.
  static func latestEmptySessionPath(threads: [[String: Any]], projectID: String) -> String? {
    guard
      let latest = sessionCatalog(
        threads: threads.filter { !isSettled($0) }, projectID: projectID
      ).first,
      let id = AppModel.threadID(from: latest.path),
      let thread = threads.first(where: { $0["id"] as? String == id }),
      thread["title"] as? String == "新任务",
      thread["status"] as? String == "idle",
      thread["latestRunId"] is NSNull,
      thread["latestVisibleMessage"] is NSNull,
      thread["latestUserMessageAt"] is NSNull,
      thread["activeRunId"] is NSNull,
      thread["pendingRuntimeRequest"] is NSNull
    else { return nil }
    return latest.path
  }

  static func sessionCatalog(threads: [[String: Any]], projectID: String?) -> [SessionItem] {
    // Match T3 client-runtime's sortActiveThreadsByOrderKey: new/reopened
    // keyless threads lead, then manually arranged threads in saved key order.
    // Lifecycle anchors belong to Server; message/output updates never move rows.
    return threads.filter {
      !($0["archivedAt"] is String)
        && (projectID == nil || $0["projectId"] as? String == projectID)
    }.compactMap {
      thread
        -> (id: String, anchorAt: Date, orderKey: String?, item: SessionItem)? in
      guard let id = thread["id"] as? String else { return nil }
      let createdAt = T3DesktopClient.date(thread["createdAt"])
      let messageValue = thread["latestMessageAt"]
      let messageAt =
        messageValue == nil || messageValue is NSNull
        ? createdAt : T3DesktopClient.date(messageValue)
      // Upstream sinks malformed timestamps to epoch, not distantPast.
      let epoch = Date(timeIntervalSince1970: 0)
      let reopenedAt = T3DesktopClient.date(thread["unsettledAt"])
      let anchorAt = max(
        createdAt == .distantPast ? epoch : createdAt,
        reopenedAt == .distantPast ? epoch : reopenedAt)
      return (
        id, anchorAt, thread["activeOrderKey"] as? String,
        SessionItem(
          path: "t3:\(id)", title: thread["title"] as? String ?? "未命名线程",
          // 不使用 updatedAt：收起、改标题等元数据操作也会更新它。
          modifiedAt: messageAt)
      )
    }.sorted {
      switch ($0.orderKey, $1.orderKey) {
      case (nil, .some): return true
      case (.some, nil): return false
      case (.some(let left), .some(let right)):
        if left != right { return left < right }
      case (nil, nil):
        if $0.anchorAt != $1.anchorAt { return $0.anchorAt > $1.anchorAt }
      }
      return $0.id < $1.id
    }.map(\.item)
  }
  /// 完成状态完全来自 Server；自动收起和手动收起走同一投影，不使用本地计时器。
  static func isSettled(_ thread: [String: Any]) -> Bool {
    thread["settledOverride"] as? String == "settled" || thread["settledAt"] is String
  }

  @Published private(set) var isSettlingIdleSessions = false
  // 仅表示正在收起，不修改 Server 的完成状态；轮询旧快照不能让会话重新闪回列表。
  @Published private(set) var pendingSettlementPaths: Set<String> = []

  /// 只接受明确的终止/空闲状态；未知状态、待处理请求及后台任务保守保留。
  static func canBulkSettle(_ thread: [String: Any]) -> Bool {
    guard let id = thread["id"] as? String, !id.isEmpty,
      !isSettled(thread), !(thread["archivedAt"] is String),
      let status = thread["status"] as? String,
      ["idle", "completed", "failed", "cancelled", "interrupted"].contains(status)
    else { return false }
    for key in ["activeRunId", "activityRunStatus", "pendingRuntimeRequest"] {
      if let value = thread[key], !(value is NSNull) { return false }
    }
    if let tasks = thread["pendingBackgroundTasks"], !(tasks is NSNull) {
      guard let tasks = tasks as? [[String: Any]], tasks.isEmpty else { return false }
    }
    return true
  }

  private func canSettleIdleSession(_ thread: [String: Any]) -> Bool {
    guard Self.canBulkSettle(thread), let id = thread["id"] as? String else { return false }
    let model = model(forSessionPath: "t3:\(id)")
    return model?.isBusy != true && (model?.queuedPrompts.isEmpty ?? true)
  }

  var idleSessionPaths: [String] {
    server.threads.filter(canSettleIdleSession)
      .compactMap { ($0["id"] as? String).map { "t3:\($0)" } }
      .filter { !pendingSettlementPaths.contains($0) }
  }

  func settleIdleSessions() {
    guard server.isConnected, !isSettlingIdleSessions else { return }
    let paths = idleSessionPaths
    guard !paths.isEmpty else { return }
    isSettlingIdleSessions = true
    // 同步移出本批全部会话，不等并发槽位、网络往返或整批刷新。
    pendingSettlementPaths.formUnion(paths)
    Task {
      defer { isSettlingIdleSessions = false }
      let (completed, unconfirmed) = await performSettlement(paths: paths) { id in
        try await self.server.dispatch(
          ["type": "thread.settle", "threadId": id], refreshAfter: false)
        self.server.requestRefresh(includeThreads: false)
      }
      do {
        try await server.refreshShell()
        selectedModel?.statusText =
          "已 Settle \(completed) 个会话"
          + (unconfirmed > 0 ? "；\(unconfirmed) 个未确认，可能已开始运行或等待处理。" : "。")
      } catch {
        selectedModel?.statusText = "批量 Settle 已提交，但列表刷新失败；请检查 Server 状态，勿重复提交。"
      }
    }
  }

  /// 固定本次范围，最多四个请求在途，避免逐个握手的累积延迟或无限并发。
  /// 每次真正提交前重查本地状态；Server 仍原子校验子树，失败不重试、不阻断其他会话。
  func performSettlement(
    paths: [String], dispatch: @escaping @MainActor (String) async throws -> Void
  ) async -> (completed: Int, unconfirmed: Int) {
    pendingSettlementPaths.formUnion(paths)
    return await withTaskGroup(of: Int.self) { group in
      var iterator = paths.makeIterator()
      var completed = 0
      var unconfirmed = 0
      func enqueue(_ path: String) {
        group.addTask { @MainActor in
          guard !Task.isCancelled,
            let id = AppModel.threadID(from: path), let thread = self.server.thread(id),
            self.canSettleIdleSession(thread)
          else {
            self.pendingSettlementPaths.remove(path)
            return 0
          }
          do {
            try await dispatch(id)
            // 成功后继续隐藏，直到 shell 确认；失败则立即恢复，允许检查后重试。
            return 1
          } catch {
            self.pendingSettlementPaths.remove(path)
            return -1
          }
        }
      }
      for _ in 0..<4 {
        if let path = iterator.next() { enqueue(path) }
      }
      while let result = await group.next() {
        if result == 1 { completed += 1 }
        if result == -1 { unconfirmed += 1 }
        if let path = iterator.next() { enqueue(path) }
      }
      return (completed, unconfirmed)
    }
  }

  enum SessionLifecycleAction {
    case settle, unsettle
    case autoSettle(enabled: Bool)

    var payload: [String: Any] {
      switch self {
      case .settle: return ["type": "thread.settle"]
      case .unsettle: return ["type": "thread.unsettle", "reason": "user"]
      case .autoSettle(let enabled):
        return ["type": "thread.auto-settle.set", "enabled": enabled]
      }
    }
  }

  func isRegeneratingSessionTitle(threadID: String) -> Bool {
    submittingTitleRegenerations.contains(threadID)
      || server.thread(threadID)?["titleRegeneration"] is [String: Any]
  }

  func regenerateSessionTitle(path: String) async {
    guard let id = AppModel.threadID(from: path),
      server.isConnected, server.supportsTitleRegeneration,
      server.thread(id) != nil, !isRegeneratingSessionTitle(threadID: id)
    else { return }
    submittingTitleRegenerations.insert(id)
    defer { submittingTitleRegenerations.remove(id) }
    do {
      // 仅提交生成意图，不发送当前标题；生成模型、上下文和并发覆盖规则均由 Server 决定。
      // 提交期间的本地锁只覆盖网络往返，后续进度以 shell 的 titleRegeneration 为准。
      try await server.dispatch(
        ["type": "thread.metadata.update", "threadId": id, "regenerateTitle": true],
        refreshAfter: false)
      try await server.refreshShell()
    } catch {
      selectedModel?.statusText = "重新生成标题未确认，请刷新 Server 状态后检查；不会自动重试。"
    }
  }

  func updateSessionLifecycle(path: String, action: SessionLifecycleAction) {
    guard let id = AppModel.threadID(from: path), server.isConnected,
      !pendingSettlementPaths.contains(path)
    else { return }
    let settling: Bool
    if case .settle = action { settling = true } else { settling = false }
    if settling { pendingSettlementPaths.insert(path) }
    Task {
      do {
        var payload = action.payload
        payload["threadId"] = id
        // 运行中、等待用户等限制由 Server 原子校验，不能仅依赖已打开的桌面标签。
        try await server.dispatch(payload, refreshAfter: false)
        try await server.refreshShell()
      } catch {
        pendingSettlementPaths.remove(path)
        selectedModel?.statusText = "会话状态更新未确认，已恢复显示；请检查 Server 状态后重试。"
      }
    }
  }

  func archiveSession(path: String) {
    guard let id = AppModel.threadID(from: path), model(forSessionPath: path)?.isBusy != true else {
      return
    }
    Task {
      do {
        // 归档只依赖线程身份；项目已不在侧栏时仍允许清理残留会话。
        try await server.dispatch(["type": "thread.archive", "threadId": id], refreshAfter: false)
        if let tab = tabs.first(where: { $0.model.currentSessionPath == path }) {
          removeTab(tab.id)
        }
        try await server.refreshShell()
      } catch { selectedModel?.statusText = "归档未确认，请刷新 Server 状态。" }
    }
  }
  func isSelectedSession(path: String) -> Bool { selectedModel?.currentSessionPath == path }
  func model(forSessionPath path: String) -> AppModel? {
    tabs.first { $0.model.currentSessionPath == path || $0.requestedSessionPath == path }?.model
  }
  func taskModel(in projectURL: URL, sessionPath: String?) -> AppModel {
    if let sessionPath, let existing = model(forSessionPath: sessionPath) { return existing }
    let model = AppModel(
      startupProjectURL: projectURL, startupSessionPath: sessionPath,
      restoreLastProjectOnLaunch: false)
    addTab(
      model: model, path: sessionPath, draft: sessionPath == nil, select: false,
      persistsDraft: sessionPath != nil)
    return model
  }
  func discardMobileDraft(_ model: AppModel) {
    guard let tab = tabs.first(where: { $0.model === model }), tab.id != selectedTabID,
      !model.hasUserMessage, !model.isBusy
    else { return }
    model.discardEmptyDraft()
    removeTab(tab.id)
  }
  func disconnectAll() {
    projectImportTask?.cancel()
    telegram.stop()
    for tab in tabs { tab.model.disconnect() }
    server.stop()
    t3Bridge.stop()
  }
  private func addTab(
    model: AppModel, path: String?, draft: Bool, select: Bool = true, persistsDraft: Bool = true
  ) {
    model.extensionUI = extensionUI
    let tab = Tab(
      id: UUID(), model: model, requestedSessionPath: path, createdAt: .now, isDraft: draft)
    tabs.append(tab)
    observations[tab.id] = Self.sidebarUpdates(for: model).sink { [weak self] _ in
      self?.objectWillChange.send()
      // Published 回调先于属性落地；延后读取，覆盖异步绑定到会话的情况。
      Task { @MainActor [weak self] in self?.acknowledgeSelectedCompletion() }
    }
    model.attach(to: server, deliveries: deliveries)
    if persistsDraft, let draftDefaults {
      let sessionPath = path ?? (model.currentSessionPath.isEmpty ? nil : model.currentSessionPath)
      if let key = Self.draftKey(sessionPath: sessionPath, projectURL: model.projectURL) {
        do {
          if let stored = draftDefaults.object(forKey: key) {
            guard let data = stored as? Data else { throw CocoaError(.coderReadCorrupt) }
            let draft = try PropertyListDecoder().decode(ComposerDraft.self, from: data)
            model.composerText = draft.text
            model.attachments = draft.attachments
          } else if let sessionPath,
            let text = draftDefaults.string(forKey: "t3Draft.\(sessionPath)")
          {
            model.composerText = text
          }
        } catch {
          model.statusText = "草稿记录损坏，无法恢复；原记录仍保留。"
        }
      }
      // 使用 Published 传出的新值，避免 willSet 时读到旧文字或旧附件。
      draftObservations[tab.id] = model.$composerText.combineLatest(
        model.$attachments, model.$currentSessionPath
      )
      .dropFirst().sink { [weak model] text, attachments, currentPath in
        guard let model else { return }
        // 迁移只改变线程身份也必须保存新归属，不能等用户再输入一个字才落盘。
        let sessionPath = currentPath.isEmpty ? path : currentPath
        guard let key = Self.draftKey(sessionPath: sessionPath, projectURL: model.projectURL)
        else { return }
        do {
          let draft = ComposerDraft(text: text, attachments: attachments)
          if draft.isEmpty {
            draftDefaults.removeObject(forKey: key)
          } else {
            draftDefaults.set(try PropertyListEncoder().encode(draft), forKey: key)
          }
          if let sessionPath {
            draftDefaults.removeObject(forKey: "t3Draft.\(sessionPath)")
          }
        } catch {
          model.statusText = "草稿保存失败，请保留输入内容后重试。"
        }
      }
    }
    if select { selectTab(tab.id) }
  }
  private static func draftKey(sessionPath: String?, projectURL: URL?) -> String? {
    if let sessionPath { return "t3ComposerDraft.session.\(sessionPath)" }
    return projectURL.map { "t3ComposerDraft.project.\($0.standardizedFileURL.path)" }
  }

  private func selectTab(_ id: UUID) {
    selectedTabID = id
    selectedModel?.enterSkillWorkspace()
    extensionUI.selectSource(selectedModel)
    acknowledgeSelectedCompletion()
    if persistsState, let project = selectedModel?.projectURL {
      UserDefaults.standard.set(project.path, forKey: "t3SelectedProject")
      if let path = selectedModel?.currentSessionPath, !path.isEmpty {
        UserDefaults.standard.set(path, forKey: "t3SelectedThread.\(project.path)")
      }
    }
  }
  private func removeTab(_ id: UUID) {
    tabs.first { $0.id == id }?.model.disconnect()
    tabs.removeAll { $0.id == id }
    observations.removeValue(forKey: id)
    draftObservations.removeValue(forKey: id)
    if selectedTabID == id {
      selectedTabID = tabs.first?.id
      selectedModel?.enterSkillWorkspace()
      if tabs.isEmpty {
        addTab(model: AppModel(restoreLastProjectOnLaunch: false), path: nil, draft: false)
      }
      acknowledgeSelectedCompletion()
    }
  }
  private func removeTabs(project: URL) {
    for id in tabs.filter({
      $0.model.projectURL?.standardizedFileURL == project.standardizedFileURL
    }).map(\.id) { removeTab(id) }
  }
  static func sidebarUpdates(for model: AppModel) -> AnyPublisher<Void, Never> {
    Publishers.MergeMany([
      model.$projectURL.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      model.$currentSessionPath.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      model.$sessionName.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      model.$isStreaming.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
    ]).eraseToAnyPublisher()
  }
  static func shouldDiscardDraftOnTabSwitch(from previousProject: URL?, to nextProject: URL?)
    -> Bool
  { false }
  func holdRemoteSubmission(_ model: AppModel) {
    remoteSubmissionHolds.insert(ObjectIdentifier(model))
  }
  func releaseRemoteSubmission(_ model: AppModel) {
    remoteSubmissionHolds.remove(ObjectIdentifier(model))
  }
  func remoteSelectionChanged() { objectWillChange.send() }
  nonisolated static func shouldRestoreSession(at path: String, now: Date = .now) -> Bool {
    path.hasPrefix("t3:")
  }
}

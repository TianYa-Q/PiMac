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
  @Published var selectedTabID: UUID?
  @Published private(set) var projectFilterPath: String?

  /// Sidebar selection filters the catalog; it never changes the active conversation.
  func toggleProjectFilter(_ project: WorkspaceProject) {
    projectFilterPath = projectFilterPath == project.id ? nil : project.id
  }

  func clearProjectFilter() { projectFilterPath = nil }

  var filteredSessions: [SessionItem] {
    let projectID = projectFilterPath.flatMap {
      server.projectID(for: URL(fileURLWithPath: $0))
    }
    if projectFilterPath != nil && projectID == nil { return [] }
    return Self.sessionCatalog(threads: server.threads, projectID: projectID)
  }

  func project(forSessionPath path: String) -> WorkspaceProject? {
    guard let id = AppModel.threadID(from: path),
      let projectID = server.thread(id)?["projectId"] as? String,
      let project = server.projects.first(where: { $0["id"] as? String == projectID }),
      let root = project["workspaceRoot"] as? String
    else { return nil }
    return WorkspaceProject(url: URL(fileURLWithPath: root), customName: project["title"] as? String)
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
  let server = T3DesktopClient()
  let git = GitWorkspaceStore()

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
  private var shellLoaded = false
  @Published private(set) var sessionCatalogRevision = 0
  private var projectImportTask: Task<Void, Never>?

  init(telegram: TelegramControl? = nil, restoreUserState: Bool = true) {
    self.telegram = telegram ?? TelegramControl()
    persistsState = restoreUserState
    gitObservation = git.$busy.removeDuplicates().dropFirst().sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    addTab(model: AppModel(restoreLastProjectOnLaunch: false), path: nil, draft: false)
    guard restoreUserState else { return }
    server.onShell = { [weak self] snapshot in self?.applyShell(snapshot) }
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
    let oldPaths =
      defaults.stringArray(forKey: "workspaceProjectPaths") ?? defaults.string(
        forKey: "lastProjectPath"
      ).map { [$0] } ?? []
    projectImportTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.server.waitUntilReady()
        for path in oldPaths where FileManager.default.fileExists(atPath: path) {
          _ = try await self.server.ensureProject(URL(fileURLWithPath: path))
        }
        self.server.requestRefresh()
      } catch { self.selectedModel?.statusText = "项目同步未完成；原项目和历史文件均未修改。" }
    }
    self.telegram.start(workspace: self)
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
    let nextProjects = (snapshot["projects"] as? [[String: Any]] ?? []).compactMap {
      project -> WorkspaceProject? in
      guard let root = project["workspaceRoot"] as? String else { return nil }
      return WorkspaceProject(
        url: URL(fileURLWithPath: root), customName: project["title"] as? String)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    if projects != nextProjects { projects = nextProjects }
    if let path = projectFilterPath, !projects.contains(where: { $0.id == path }) {
      clearProjectFilter()
    }
    if sessionCatalogRevision != server.sessionCatalogRevision {
      sessionCatalogRevision = server.sessionCatalogRevision
    }
    for tab in tabs {
      tab.model.refreshCodexAccounts()
      if let project = tab.model.projectURL { tab.model.updateCatalog(sessions(in: project)) }
      if let id = tab.model.threadID, server.thread(id) == nil, !tab.model.isLoadingConfiguration {
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
  }

  func addProject(_ projectURL: URL) {
    guard FileManager.default.fileExists(atPath: projectURL.path) else { return }
    Task {
      do {
        _ = try await server.ensureProject(projectURL)
        try await server.refresh()
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
      openSession(path: path, in: project.url, markRead: false)
    } else if let recent = catalog.first {
      openSession(path: recent.path, in: project.url, markRead: false)
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
        try await server.refresh()
      } catch { selectedModel?.statusText = "项目重命名未确认，请刷新 Server 状态。" }
    }
  }

  func removeProject(_ project: WorkspaceProject) {
    guard let id = server.projectID(for: project.url),
      !server.threads.contains(where: {
        $0["projectId"] as? String == id
          && ($0["latestTurn"] as? [String: Any])?["state"] as? String == "running"
      })
    else { return }
    Task {
      do {
        try await server.dispatch(["type": "project.delete", "projectId": id, "force": true])
        removeTabs(project: project.url)
        try await server.refresh()
      } catch { selectedModel?.statusText = "移除项目未确认，请刷新 Server 状态。" }
    }
  }
  /// 新聊天优先使用侧栏筛选项目；筛选本身不切换或修改当前会话。
  func newSessionInLastProject() {
    if let path = projectFilterPath {
      newSession(in: URL(fileURLWithPath: path))
      return
    }
    let savedPath = persistsState ? UserDefaults.standard.string(forKey: "t3SelectedProject") : nil
    guard let project = selectedProject
      ?? projects.first(where: { $0.id == savedPath })
      ?? projects.first
    else { return }
    newSession(in: project.url)
  }

  func newSession(in projectURL: URL) {
    // Also reuse a draft while its thread.create is still in flight, even when
    // another tab is selected. Do not depend on a shell refresh between clicks.
    let reusablePath = server.projectID(for: projectURL).flatMap {
      Self.latestEmptySessionPath(threads: server.threads, projectID: $0)
    }
    if let tab = tabs.last(where: {
      $0.model.projectURL?.standardizedFileURL == projectURL.standardizedFileURL
    }), tab.isDraft,
      (tab.model.currentSessionPath.isEmpty || tab.model.currentSessionPath == reusablePath
        || tab.model.threadID.map({ server.thread($0) == nil }) == true),
      !tab.model.hasUserMessage, !tab.model.hasUnsubmittedInput, !tab.model.isBusy,
      tab.model.queuedPrompts.isEmpty
    {
      selectTab(tab.id)
      return
    }
    if let path = reusablePath,
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
  func openSession(path: String, in projectURL: URL, markRead: Bool = true) {
    guard let id = AppModel.threadID(from: path), let thread = server.thread(id),
      thread["projectId"] as? String == server.projectID(for: projectURL)
    else {
      selectedModel?.statusText = "此历史路径尚未导入 T3；不会启动旧桌面 Pi 进程。"
      return
    }
    if markRead, T3V2Presentation.hasUnreadCompletion(thread),
      let completedAt = thread["latestRunCompletedAt"] as? String
    {
      // Acknowledge only the completion visible at click time, never a later
      // run that finishes while the request is waiting for Server readiness.
      Task {
        do {
          try await server.dispatch([
            "type": "thread.visit", "threadId": id, "visitedAt": completedAt,
          ])
        } catch {
          selectedModel?.statusText = "已读状态同步未确认，请重新点击会话。"
        }
      }
    }
    if let tab = tabs.first(where: {
      $0.model.currentSessionPath == path || $0.requestedSessionPath == path
    }) {
      selectTab(tab.id)
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
    guard let latest = sessionCatalog(threads: threads, projectID: projectID).first,
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
    return threads.filter { projectID == nil || $0["projectId"] as? String == projectID }.compactMap {
      thread
        -> (id: String, anchorAt: Date, orderKey: String?, item: SessionItem)? in
      guard let id = thread["id"] as? String else { return nil }
      let createdAt = T3DesktopClient.date(thread["createdAt"])
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
          modifiedAt: T3DesktopClient.date(thread["updatedAt"]))
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
  func archiveSession(path: String, in projectURL: URL) {
    guard let id = AppModel.threadID(from: path), model(forSessionPath: path)?.isBusy != true else {
      return
    }
    Task {
      do {
        try await server.dispatch(["type": "thread.archive", "threadId": id])
        if let tab = tabs.first(where: { $0.model.currentSessionPath == path }) {
          removeTab(tab.id)
        }
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
    addTab(model: model, path: sessionPath, draft: sessionPath == nil, select: false)
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
  private func addTab(model: AppModel, path: String?, draft: Bool, select: Bool = true) {
    model.extensionUI = extensionUI
    let tab = Tab(
      id: UUID(), model: model, requestedSessionPath: path, createdAt: .now, isDraft: draft)
    tabs.append(tab)
    observations[tab.id] = Self.sidebarUpdates(for: model).sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    if persistsState {
      if let path, let text = UserDefaults.standard.string(forKey: "t3Draft.\(path)") {
        model.composerText = text
      }
      draftObservations[tab.id] = model.$composerText.dropFirst().sink { [weak model] text in
        guard let path = model?.currentSessionPath, !path.isEmpty else { return }
        UserDefaults.standard.set(text, forKey: "t3Draft.\(path)")
      }
    }
    model.attach(to: server)
    if select { selectTab(tab.id) }
  }
  private func selectTab(_ id: UUID) {
    selectedTabID = id
    extensionUI.selectSource(selectedModel)
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
      if tabs.isEmpty {
        addTab(model: AppModel(restoreLastProjectOnLaunch: false), path: nil, draft: false)
      }
    }
  }
  private func removeTabs(project: URL) {
    for id in tabs.filter({ $0.model.projectURL == project }).map(\.id) { removeTab(id) }
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

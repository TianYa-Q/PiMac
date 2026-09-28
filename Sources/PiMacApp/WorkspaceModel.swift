import Combine
import Foundation

struct WorkspaceProject: Identifiable, Hashable {
  let url: URL

  var id: String { url.standardizedFileURL.path }
  var name: String { url.lastPathComponent }
}

@MainActor
final class WorkspaceModel: ObservableObject {
  private struct ComposerDraft: Codable {
    let sessionPath: String?
    let text: String
  }

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
  let extensionUI = ExtensionUIModel()
  let telegram = TelegramControl()

  private static let savedProjectsKey = "workspaceProjectPaths"
  private static let activeProjectKey = "workspaceActiveProjectPath"
  private static let archivedSessionsKey = "workspaceArchivedSessionPaths"
  private static let sessionCatalogsKey = "workspaceSessionCatalogs"
  private static let composerDraftsKey = "workspaceComposerDrafts"
  private static let lastSessionByProjectKey = "workspaceLastSessionByProject"
  private static let sessionRestoreInterval: TimeInterval = 5 * 60
  private static let maximumLiveProcesses = 4
  private static let idleProcessLifetime: Duration = .seconds(10 * 60)
  private var observations: [UUID: AnyCancellable] = [:]
  private var streamingObservations: [UUID: AnyCancellable] = [:]
  private var sessionObservations: [UUID: AnyCancellable] = [:]
  private var composerDraftObservations: [UUID: AnyCancellable] = [:]
  private var selectedTabByProject: [String: UUID] = [:]
  private var sessionCatalogs: [String: [SessionItem]]
  private var lastSessionByProject: [String: String]
  private var sessionCatalogRefreshedAt: [String: Date] = [:]
  private var composerDrafts: [String: ComposerDraft]
  private var composerDraftSaveTask: Task<Void, Never>?
  private var sessionCatalogGenerations: [String: UUID] = [:]
  private var lastUsedAt: [UUID: Date] = [:]
  private var idleProcessTasks: [UUID: Task<Void, Never>] = [:]
  private var archivedSessionPaths: Set<String>

  init() {
    let defaults = UserDefaults.standard
    archivedSessionPaths = Set(defaults.stringArray(forKey: Self.archivedSessionsKey) ?? [])
    sessionCatalogs = Self.readSessionCatalogs(from: defaults)
    lastSessionByProject =
      defaults.dictionary(forKey: Self.lastSessionByProjectKey) as? [String: String] ?? [:]
    composerDrafts = Self.readComposerDrafts(from: defaults)
    let savedPaths = defaults.stringArray(forKey: Self.savedProjectsKey) ?? []
    let fallbackPath = defaults.string(forKey: "lastProjectPath")
    let paths = savedPaths.isEmpty ? fallbackPath.map { [$0] } ?? [] : savedPaths
    projects = paths.compactMap(Self.validProject(path:))

    let activePath = defaults.string(forKey: Self.activeProjectKey)
    if let project = projects.first(where: { $0.id == activePath }) ?? projects.first {
      let now = Date.now
      let cutoff = now.addingTimeInterval(-Self.sessionRestoreInterval)
      let archivedPaths = archivedSessionPaths
      Task { [weak self] in
        let path = await Task.detached(priority: .utility) {
          AppModel.mostRecentConversationSession(
            for: project.id, since: cutoff, now: now, archivedPaths: archivedPaths)
        }.value
        guard let self, self.selectedTabID == nil,
          self.projects.contains(where: { $0.id == project.id })
        else { return }
        if let path {
          self.openSession(path: path, in: project.url)
        } else {
          self.newSession(in: project.url)
        }
      }
    } else {
      addTab(
        model: AppModel(restoreLastProjectOnLaunch: false), requestedSessionPath: nil,
        isDraft: false)
    }

    // Cached catalogs are immediately available for the sidebar. Refresh a project when it is
    // selected (or its active RPC session loads), not every saved project during app launch.
    telegram.start(workspace: self)
  }

  var canRestartSafely: Bool {
    telegram.canRestartSafely
      && tabs.allSatisfy { tab in
        let model = tab.model
        return model.canRestartSafely && !extensionUI.hasPendingRequests(from: model)
      }
  }

  var selectedModel: AppModel? {
    tabs.first(where: { $0.id == selectedTabID })?.model
  }

  var selectedProject: WorkspaceProject? {
    guard let url = selectedModel?.projectURL else { return nil }
    return WorkspaceProject(url: url)
  }

  func addProject(_ projectURL: URL) {
    let project = WorkspaceProject(url: projectURL.standardizedFileURL)
    guard FileManager.default.fileExists(atPath: project.id) else { return }
    if !projects.contains(where: { $0.id == project.id }) {
      projects.append(project)
      projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      persistProjects()
      refreshSessionCatalog(for: project.url)
    }
    selectProject(project)
  }

  func selectProject(_ project: WorkspaceProject) {
    refreshSessionCatalog(for: project.url, ifStale: true)
    if let tabID = selectedTabByProject[project.id], tabs.contains(where: { $0.id == tabID }) {
      selectTab(tabID)
      return
    }
    if let existing = tabs.last(where: {
      $0.model.projectURL?.standardizedFileURL.path == project.id
    }) {
      selectTab(existing.id)
      return
    }
    // Switching projects must keep the previous project's selected draft/tab intact.
    openLastSessionTab(for: project)
  }

  private func openLastSessionTab(for project: WorkspaceProject) {
    // Project switching retains its last selected session; the five-minute rule applies to launch.
    let path = lastSessionByProject[project.id].flatMap {
      !archivedSessionPaths.contains($0) && FileManager.default.fileExists(atPath: $0) ? $0 : nil
    }
    let draft = composerDrafts[project.id]
    addTab(
      model: AppModel(
        startupProjectURL: project.url,
        continueLastSession: path == nil,
        startupSessionPath: path,
        initialComposerText: draft?.sessionPath == path ? draft?.text ?? "" : ""
      ),
      requestedSessionPath: path,
      isDraft: false
    )
  }

  func removeProject(_ project: WorkspaceProject) {
    let matchingTabs = tabs.filter { $0.model.projectURL?.standardizedFileURL.path == project.id }
    for tab in matchingTabs {
      if tab.isDraft && !tab.model.hasUserMessage {
        tab.model.discardEmptyDraft()
      } else {
        tab.model.disconnect()
      }
      observations.removeValue(forKey: tab.id)
      streamingObservations.removeValue(forKey: tab.id)
      sessionObservations.removeValue(forKey: tab.id)
      composerDraftObservations.removeValue(forKey: tab.id)
      idleProcessTasks.removeValue(forKey: tab.id)?.cancel()
      lastUsedAt.removeValue(forKey: tab.id)
    }
    tabs.removeAll { $0.model.projectURL?.standardizedFileURL.path == project.id }
    projects.removeAll { $0.id == project.id }
    selectedTabByProject.removeValue(forKey: project.id)
    sessionCatalogs.removeValue(forKey: project.id)
    sessionCatalogRefreshedAt.removeValue(forKey: project.id)
    lastSessionByProject.removeValue(forKey: project.id)
    UserDefaults.standard.set(lastSessionByProject, forKey: Self.lastSessionByProjectKey)
    composerDrafts.removeValue(forKey: project.id)
    flushComposerDrafts()
    sessionCatalogGenerations.removeValue(forKey: project.id)
    loadingSessionCatalogs.remove(project.id)
    persistProjects()
    persistSessionCatalogs()

    if let next = projects.first {
      selectProject(next)
    } else {
      addTab(
        model: AppModel(restoreLastProjectOnLaunch: false), requestedSessionPath: nil,
        isDraft: false)
    }
  }

  func newSession(in projectURL: URL) {
    let projectPath = projectURL.standardizedFileURL.path
    if let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }),
      tabs[selectedIndex].model.projectURL?.standardizedFileURL.path == projectPath
    {
      let tab = tabs[selectedIndex]
      // Clicking New again on an untouched draft should not throw away a warm process just to
      // create an equivalent draft.
      if tab.isDraft, !tab.model.hasUserMessage, !tab.model.hasUnsubmittedInput,
        !tab.model.isBusy
      {
        selectTab(tab.id)
        return
      }
      // An idle RPC process can replace its active session in place. Busy sessions still get a
      // separate process so background work remains genuinely concurrent.
      if tab.model.canReuseProcessForNewSession,
        !extensionUI.hasPendingRequests(from: tab.model)
      {
        // Change the workspace selection state before waiting for Pi's new_session reply. AppModel
        // also clears its visible transcript optimistically, so New Task opens on this run loop.
        let previousRequestedPath = tab.requestedSessionPath
        let previousCreatedAt = tab.createdAt
        let previousIsDraft = tab.isDraft
        tabs[selectedIndex].requestedSessionPath = nil
        tabs[selectedIndex].createdAt = .now
        tabs[selectedIndex].isDraft = true
        lastUsedAt[tab.id] = .now

        tab.model.newSession { [weak self, weak model = tab.model] created in
          guard let self, let model,
            let index = self.tabs.firstIndex(where: { $0.model === model })
          else { return }
          if !created {
            self.tabs[index].requestedSessionPath = previousRequestedPath
            self.tabs[index].createdAt = previousCreatedAt
            self.tabs[index].isDraft = previousIsDraft
          }
          self.lastUsedAt[self.tabs[index].id] = .now
        }
        return
      }
    }

    discardSelectedDraftIfEmpty()
    addTab(
      model: AppModel(startupProjectURL: projectURL, continueLastSession: false),
      requestedSessionPath: nil,
      isDraft: true
    )
  }

  func openSession(path: String, in projectURL: URL) {
    if archivedSessionPaths.remove(path) != nil { persistArchivedSessions() }
    if let existing = tabs.first(where: {
      $0.requestedSessionPath == path || $0.model.currentSessionPath == path
    }) {
      existing.model.refreshSessionMetadata()
      selectTab(existing.id)
      return
    }
    discardSelectedDraftIfEmpty()
    let projectPath = projectURL.standardizedFileURL.path
    let savedDraft = composerDrafts[projectPath]
    addTab(
      model: AppModel(
        startupProjectURL: projectURL,
        continueLastSession: false,
        startupSessionPath: path,
        initialComposerText: savedDraft?.sessionPath == path ? savedDraft?.text ?? "" : ""
      ),
      requestedSessionPath: path,
      isDraft: false
    )
  }

  /// 保留给旧视图代码；现在选择目录只会加入工作区，不再关闭其他项目。
  func replaceProject(with projectURL: URL) {
    addProject(projectURL)
  }

  /// Telegram uses separate RPC processes. Refresh the sidebar catalog and any desktop tab
  /// showing the same persisted session after that process writes to disk.
  func remoteSessionChanged(in projectURL: URL?, sessionPath: String) {
    guard let projectURL else { return }
    refreshSessionCatalog(for: projectURL)
    guard !sessionPath.isEmpty else { return }
    for tab in tabs
    where tab.model.projectURL?.standardizedFileURL == projectURL.standardizedFileURL {
      tab.model.refreshExternalTranscript(at: sessionPath)
    }
  }

  func isLoadingSessions(in projectURL: URL) -> Bool {
    loadingSessionCatalogs.contains(projectURL.standardizedFileURL.path)
  }

  func sessions(in projectURL: URL) -> [SessionItem] {
    let projectPath = projectURL.standardizedFileURL.path
    var merged = Dictionary(
      uniqueKeysWithValues: (sessionCatalogs[projectPath] ?? []).map { ($0.path, $0) })
    for tab in tabs where tab.model.projectURL?.standardizedFileURL.path == projectPath {
      for session in tab.model.sessions {
        if let previous = merged[session.path], previous.modifiedAt >= session.modifiedAt {
          continue
        }
        merged[session.path] = session
      }
      let path = tab.model.currentSessionPath
      if !path.isEmpty,
        tab.model.hasUserMessage || tab.model.hasUnsubmittedInput,
        merged[path] == nil
      {
        let firstPrompt = tab.model.messages.first(where: { $0.kind == .user })?.text
        let draftText = tab.model.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = firstPrompt ?? (draftText.isEmpty ? "未命名会话" : draftText)
        let title =
          tab.model.sessionName.isEmpty
          ? String(fallbackTitle.prefix(70)) : tab.model.sessionName
        merged[path] = SessionItem(path: path, title: title, modifiedAt: tab.createdAt)
      }
    }
    return merged.values
      .filter { !archivedSessionPaths.contains($0.path) }
      .sorted { $0.modifiedAt > $1.modifiedAt }
  }

  func archiveSession(path: String, in projectURL: URL) {
    guard model(forSessionPath: path)?.isBusy != true else { return }
    archivedSessionPaths.insert(path)
    let projectPath = projectURL.standardizedFileURL.path
    sessionCatalogs[projectPath]?.removeAll { $0.path == path }
    if lastSessionByProject[projectPath] == path {
      lastSessionByProject.removeValue(forKey: projectPath)
      UserDefaults.standard.set(lastSessionByProject, forKey: Self.lastSessionByProjectKey)
    }
    persistArchivedSessions()
    persistSessionCatalogs()

    let removed = tabs.filter {
      $0.requestedSessionPath == path || $0.model.currentSessionPath == path
    }
    let removedIDs = Set(removed.map(\.id))
    let removedSelectedTab = selectedTabID.map(removedIDs.contains) ?? false
    for tab in removed {
      observations.removeValue(forKey: tab.id)
      streamingObservations.removeValue(forKey: tab.id)
      sessionObservations.removeValue(forKey: tab.id)
      composerDraftObservations.removeValue(forKey: tab.id)
      idleProcessTasks.removeValue(forKey: tab.id)?.cancel()
      lastUsedAt.removeValue(forKey: tab.id)
      tab.model.disconnect()
    }
    tabs.removeAll { removedIDs.contains($0.id) }

    guard removedSelectedTab else {
      objectWillChange.send()
      return
    }
    if let replacement = tabs.last(where: {
      $0.model.projectURL?.standardizedFileURL.path == projectPath
    }) {
      selectTab(replacement.id)
    } else {
      addTab(
        model: AppModel(startupProjectURL: projectURL, continueLastSession: false),
        requestedSessionPath: nil,
        isDraft: true
      )
    }
  }

  func isSelectedSession(path: String) -> Bool {
    guard let tab = tabs.first(where: { $0.id == selectedTabID }) else { return false }
    return tab.requestedSessionPath == path || tab.model.currentSessionPath == path
  }

  func model(forSessionPath path: String) -> AppModel? {
    tabs.first(where: {
      $0.requestedSessionPath == path || $0.model.currentSessionPath == path
    })?.model
  }

  func disconnectAll() {
    telegram.stop()
    if let selected = tabs.first(where: { $0.id == selectedTabID }),
      selected.model.hasUserMessage,
      let projectPath = selected.model.projectURL?.standardizedFileURL.path
    {
      let sessionPath = selected.model.currentSessionPath
      if !sessionPath.isEmpty { rememberSession(sessionPath, in: projectPath) }
    }
    flushComposerDrafts()
    sessionObservations.removeAll()
    for task in idleProcessTasks.values { task.cancel() }
    idleProcessTasks.removeAll()
    for tab in tabs {
      if tab.isDraft && !tab.model.hasUserMessage {
        tab.model.discardEmptyDraft()
      } else {
        tab.model.disconnect()
      }
    }
  }

  static func sidebarUpdates(for model: AppModel) -> AnyPublisher<Void, Never> {
    Publishers.MergeMany([
      model.$projectURL.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      model.$currentSessionPath.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      model.$sessionName.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      model.$isStreaming.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      model.$isCompacting.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
    ]).eraseToAnyPublisher()
  }

  private func addTab(model: AppModel, requestedSessionPath: String?, isDraft: Bool) {
    model.extensionUI = extensionUI
    let tab = Tab(
      id: UUID(), model: model, requestedSessionPath: requestedSessionPath, createdAt: .now,
      isDraft: isDraft)
    tabs.append(tab)
    // Transcript deltas, diagnostics and token counters are observed by the chat itself.
    // Forward only sidebar metadata, not every token from every background process.
    observations[tab.id] = Self.sidebarUpdates(for: model)
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak model] _ in
        guard let self, let model else { return }
        self.synchronizeProject(for: model)
        self.objectWillChange.send()
      }
    lastUsedAt[tab.id] = .now
    streamingObservations[tab.id] = Publishers.CombineLatest(
      model.$isStreaming, model.$isCompacting
    )
    .map { $0 || $1 }
    .removeDuplicates()
    .dropFirst()
    .sink { [weak self] isBusy in
      Task { @MainActor [weak self] in
        self?.activityStateChanged(for: tab.id, isBusy: isBusy)
      }
    }
    sessionObservations[tab.id] = model.$sessions
      .dropFirst()
      .sink { [weak self, weak model] sessions in
        Task { @MainActor [weak self, weak model] in
          guard let self, let projectURL = model?.projectURL else { return }
          self.updateSessionCatalog(sessions, for: projectURL)
        }
      }
    composerDraftObservations[tab.id] = Publishers.CombineLatest(
      model.$composerText, model.$currentSessionPath
    )
    .dropFirst()
    .sink { [weak self] _, sessionPath in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.persistComposerDraft(for: tab.id)
        if self.selectedTabID == tab.id,
          self.tabs.first(where: { $0.id == tab.id })?.isDraft == false,
          !sessionPath.isEmpty,
          let projectPath = model.projectURL?.standardizedFileURL.path
        {
          self.rememberSession(sessionPath, in: projectPath)
        }
      }
    }
    // AppModel's initializer schedules its own connection; selecting a brand-new tab must not
    // start a second RPC process before that deferred connection runs.
    selectTab(tab.id, startProcessIfNeeded: false)
  }

  static func shouldDiscardDraftOnTabSwitch(from previousProject: URL?, to nextProject: URL?)
    -> Bool
  {
    guard let previousProject, let nextProject else { return false }
    return previousProject.standardizedFileURL.path == nextProject.standardizedFileURL.path
  }

  private func selectTab(_ id: UUID, startProcessIfNeeded: Bool = true) {
    let previousID = selectedTabID
    guard let selected = tabs.first(where: { $0.id == id }) else { return }
    if id != previousID,
      Self.shouldDiscardDraftOnTabSwitch(
        from: tabs.first(where: { $0.id == previousID })?.model.projectURL,
        to: selected.model.projectURL)
    {
      discardSelectedDraftIfEmpty(except: id)
    }
    selectedTabID = id
    persistComposerDraft(for: id)
    // Commit pending editor changes when switching tabs.
    flushComposerDrafts()

    idleProcessTasks.removeValue(forKey: id)?.cancel()
    lastUsedAt[id] = .now
    if startProcessIfNeeded && !selected.model.isProcessRunning {
      selected.model.resumeProcess(
        sessionPath: selected.requestedSessionPath,
        continueLastSession: !selected.isDraft
      )
    }
    extensionUI.selectSource(selected.model)
    if let path = selected.model.projectURL?.standardizedFileURL.path {
      selectedTabByProject[path] = id
      UserDefaults.standard.set(path, forKey: Self.activeProjectKey)
      let sessionPath = selected.requestedSessionPath ?? selected.model.currentSessionPath
      if !sessionPath.isEmpty && !selected.isDraft {
        rememberSession(sessionPath, in: path)
      }
    }
    if let previousID, previousID != id { scheduleProcessSuspension(for: previousID) }
    trimProcessPool()
  }

  private func activityStateChanged(for id: UUID, isBusy: Bool) {
    if isBusy {
      idleProcessTasks.removeValue(forKey: id)?.cancel()
      lastUsedAt[id] = .now
    } else if id != selectedTabID {
      scheduleProcessSuspension(for: id)
      trimProcessPool()
    }
  }

  private func scheduleProcessSuspension(for id: UUID) {
    idleProcessTasks.removeValue(forKey: id)?.cancel()
    guard id != selectedTabID,
      let tab = tabs.first(where: { $0.id == id }),
      tab.model.isProcessRunning,
      !tab.model.isBusy,
      tab.model.queuedPrompts.isEmpty,
      !extensionUI.hasPendingRequests(from: tab.model)
    else { return }

    idleProcessTasks[id] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.idleProcessLifetime)
      guard !Task.isCancelled else { return }
      self?.suspendProcess(for: id)
    }
  }

  private func trimProcessPool() {
    var liveCount = tabs.filter { $0.model.isProcessRunning }.count
    guard liveCount > Self.maximumLiveProcesses else { return }
    let candidates =
      tabs
      .filter {
        $0.id != selectedTabID && $0.model.isProcessRunning && !$0.model.isBusy
          && $0.model.queuedPrompts.isEmpty && !extensionUI.hasPendingRequests(from: $0.model)
      }
      .sorted {
        (lastUsedAt[$0.id] ?? .distantPast) < (lastUsedAt[$1.id] ?? .distantPast)
      }
    for tab in candidates where liveCount > Self.maximumLiveProcesses {
      suspendProcess(for: tab.id)
      liveCount -= 1
    }
  }

  private func suspendProcess(for id: UUID) {
    idleProcessTasks.removeValue(forKey: id)?.cancel()
    guard id != selectedTabID,
      let tab = tabs.first(where: { $0.id == id }),
      !tab.model.isBusy,
      tab.model.queuedPrompts.isEmpty,
      !extensionUI.hasPendingRequests(from: tab.model)
    else { return }
    if let projectURL = tab.model.projectURL { refreshSessionCatalog(for: projectURL) }
    tab.model.suspendProcess()
  }

  private func discardSelectedDraftIfEmpty(except retainedID: UUID? = nil) {
    guard let id = selectedTabID, id != retainedID,
      let tab = tabs.first(where: { $0.id == id }), tab.isDraft,
      !tab.model.hasUserMessage, !tab.model.hasUnsubmittedInput, !tab.model.isBusy
    else { return }
    observations.removeValue(forKey: id)
    streamingObservations.removeValue(forKey: id)
    sessionObservations.removeValue(forKey: id)
    composerDraftObservations.removeValue(forKey: id)
    idleProcessTasks.removeValue(forKey: id)?.cancel()
    lastUsedAt.removeValue(forKey: id)
    tab.model.discardEmptyDraft()
    tabs.removeAll { $0.id == id }
    selectedTabID = nil
  }

  private func synchronizeProject(for model: AppModel) {
    guard let url = model.projectURL?.standardizedFileURL else { return }
    let project = WorkspaceProject(url: url)
    if !projects.contains(where: { $0.id == project.id }) {
      projects.append(project)
      projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      persistProjects()
    }
    if model === selectedModel, let selectedTabID {
      selectedTabByProject[project.id] = selectedTabID
    }
  }

  private func rememberSession(_ sessionPath: String, in projectPath: String) {
    guard lastSessionByProject[projectPath] != sessionPath else { return }
    lastSessionByProject[projectPath] = sessionPath
    UserDefaults.standard.set(lastSessionByProject, forKey: Self.lastSessionByProjectKey)
  }

  private func refreshSessionCatalog(for projectURL: URL, ifStale: Bool = false) {
    let projectPath = projectURL.standardizedFileURL.path
    if ifStale {
      if loadingSessionCatalogs.contains(projectPath) { return }
      if let refreshedAt = sessionCatalogRefreshedAt[projectPath],
        Date.now.timeIntervalSince(refreshedAt) < 30
      {
        return
      }
    }
    let generation = UUID()
    sessionCatalogGenerations[projectPath] = generation
    loadingSessionCatalogs.insert(projectPath)
    Task { [weak self] in
      let sessions = await Task.detached(priority: .utility) {
        AppModel.discoverSessions(for: projectPath)
      }.value
      guard let self,
        self.projects.contains(where: { $0.id == projectPath }),
        self.sessionCatalogGenerations[projectPath] == generation
      else { return }
      self.loadingSessionCatalogs.remove(projectPath)
      self.sessionCatalogRefreshedAt[projectPath] = .now
      self.updateSessionCatalog(sessions, forPath: projectPath)
    }
  }

  private func updateSessionCatalog(_ sessions: [SessionItem], for projectURL: URL) {
    updateSessionCatalog(sessions, forPath: projectURL.standardizedFileURL.path)
  }

  private func updateSessionCatalog(_ sessions: [SessionItem], forPath projectPath: String) {
    if sessionCatalogs[projectPath] != sessions {
      objectWillChange.send()
      sessionCatalogs[projectPath] = sessions
      persistSessionCatalogs()
    }
  }

  private func persistProjects() {
    UserDefaults.standard.set(projects.map(\.id), forKey: Self.savedProjectsKey)
  }

  private func persistSessionCatalogs() {
    guard let data = try? JSONEncoder().encode(sessionCatalogs) else { return }
    UserDefaults.standard.set(data, forKey: Self.sessionCatalogsKey)
  }

  private func persistComposerDraft(for tabID: UUID) {
    guard tabID == selectedTabID,
      let tab = tabs.first(where: { $0.id == tabID }),
      let projectPath = tab.model.projectURL?.standardizedFileURL.path
    else { return }

    let text = tab.model.composerText
    if text.isEmpty {
      composerDrafts.removeValue(forKey: projectPath)
    } else {
      let currentPath = tab.model.currentSessionPath
      let sessionPath = tab.requestedSessionPath ?? (currentPath.isEmpty ? nil : currentPath)
      composerDrafts[projectPath] = ComposerDraft(sessionPath: sessionPath, text: text)
    }
    composerDraftSaveTask?.cancel()
    composerDraftSaveTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      self?.persistComposerDrafts()
      self?.composerDraftSaveTask = nil
    }
  }

  private func flushComposerDrafts() {
    composerDraftSaveTask?.cancel()
    composerDraftSaveTask = nil
    persistComposerDrafts()
  }

  private func persistComposerDrafts() {
    guard let data = try? JSONEncoder().encode(composerDrafts) else { return }
    UserDefaults.standard.set(data, forKey: Self.composerDraftsKey)
  }

  private func persistArchivedSessions() {
    UserDefaults.standard.set(Array(archivedSessionPaths), forKey: Self.archivedSessionsKey)
  }

  private static func readSessionCatalogs(
    from defaults: UserDefaults
  ) -> [String: [SessionItem]] {
    guard let data = defaults.data(forKey: sessionCatalogsKey),
      let catalogs = try? JSONDecoder().decode([String: [SessionItem]].self, from: data)
    else { return [:] }
    return catalogs
  }

  private static func readComposerDrafts(
    from defaults: UserDefaults
  ) -> [String: ComposerDraft] {
    guard let data = defaults.data(forKey: composerDraftsKey),
      let drafts = try? JSONDecoder().decode([String: ComposerDraft].self, from: data)
    else { return [:] }
    return drafts
  }

  nonisolated private static func validProject(path: String) -> WorkspaceProject? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }
    return WorkspaceProject(url: URL(fileURLWithPath: path, isDirectory: true))
  }
}

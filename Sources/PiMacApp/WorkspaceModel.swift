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
  let telegram: TelegramControl
  let t3Bridge = T3BridgeService()

  private static let savedProjectsKey = "workspaceProjectPaths"
  private static let activeProjectKey = "workspaceActiveProjectPath"
  private static let archivedSessionsKey = "workspaceArchivedSessionPaths"
  private static let sessionCatalogsKey = "workspaceSessionCatalogs"
  private static let composerDraftsKey = "workspaceComposerDrafts"
  private static let lastSessionByProjectKey = "workspaceLastSessionByProject"
  nonisolated private static let sessionRestoreInterval: TimeInterval = 30 * 60
  private static let maximumLiveProcesses = 4
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

  init(telegram: TelegramControl? = nil, restoreUserState: Bool = true) {
    self.telegram = telegram ?? TelegramControl()
    archivedSessionPaths = []
    sessionCatalogs = [:]
    lastSessionByProject = [:]
    composerDrafts = [:]
    // Bridge fixtures must not restore user conversations, poll a real bot,
    // or start a development sidecar while testing their isolated child.
    if !restoreUserState {
      addTab(
        model: AppModel(restoreLastProjectOnLaunch: false, remembersDesktopProject: false),
        requestedSessionPath: nil, isDraft: false)
      return
    }
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
    self.telegram.start(workspace: self)
    // Restore only explicitly confirmed network consent and the exact endpoint.
    // A development-only loopback opt-in must not replace the saved connection.
    let restoredT3Connection = t3Bridge.restoreRememberedConnection(workspace: self)
    let environment = ProcessInfo.processInfo.environment
    if !restoredT3Connection, environment["PIMAC_T3_BRIDGE"] == "1",
      let token = environment["PIMAC_T3_BRIDGE_TOKEN"]
    {
      do { try t3Bridge.start(workspace: self, token: token) } catch {
        NSLog("Pi Mac internal T3 bridge could not start")
      }
    }
  }

  var canRestartSafely: Bool {
    remoteSubmissionHolds.isEmpty && telegram.canRestartSafely
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
    if let tabID = selectedTabByProject[project.id],
      let tab = tabs.first(where: {
        $0.id == tabID && $0.model.projectURL?.standardizedFileURL.path == project.id
      })
    {
      selectProjectTab(tab, in: project)
      return
    }
    if let existing = tabs.last(where: {
      $0.model.projectURL?.standardizedFileURL.path == project.id
    }) {
      selectProjectTab(existing, in: project)
      return
    }
    openLastSessionTab(for: project)
  }

  nonisolated static func shouldRestoreSession(at path: String, now: Date = .now) -> Bool {
    guard !path.isEmpty,
      let date = AppModel.latestConversationMessageDate(inFile: URL(fileURLWithPath: path))
    else { return false }
    return date >= now.addingTimeInterval(-sessionRestoreInterval) && date <= now
  }

  private func selectProjectTab(_ tab: Tab, in project: WorkspaceProject) {
    if tab.id == selectedTabID { return }
    let path = tab.requestedSessionPath ?? tab.model.currentSessionPath
    if !tab.isDraft, !tab.model.isBusy, !tab.model.hasUnsubmittedInput,
      !Self.shouldRestoreSession(at: path)
    {
      newSession(in: project.url)
    } else if !tab.model.isProcessRunning, !path.isEmpty, reusableTab() != nil {
      openSession(path: path, in: project.url)
    } else {
      selectTab(tab.id)
    }
  }

  private func openLastSessionTab(for project: WorkspaceProject) {
    let path =
      lastSessionByProject[project.id].flatMap {
        !archivedSessionPaths.contains($0) && FileManager.default.fileExists(atPath: $0) ? $0 : nil
      }
      ?? sessionCatalogs[project.id]?
      .filter {
        !archivedSessionPaths.contains($0.path) && FileManager.default.fileExists(atPath: $0.path)
      }
      .max(by: { $0.modifiedAt < $1.modifiedAt })?.path
    let draft = composerDrafts[project.id]
    if let path,
      Self.shouldRestoreSession(at: path)
        || (draft?.sessionPath == path && draft?.text.isEmpty == false)
    {
      openSession(path: path, in: project.url)
      return
    }
    addTab(
      model: AppModel(
        startupProjectURL: project.url,
        continueLastSession: false,
        initialComposerText: draft?.sessionPath == nil ? draft?.text ?? "" : ""
      ),
      requestedSessionPath: nil,
      isDraft: true
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
        !telegram.retainsSession(tab.model),
        !tab.model.hasUnsubmittedInput,
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
    let projectPath = projectURL.standardizedFileURL.path
    var suspendedTarget: Tab?
    if let existing = tabs.first(where: {
      $0.model.projectURL?.standardizedFileURL.path == projectPath
        && ($0.requestedSessionPath == path || $0.model.currentSessionPath == path)
    }) {
      if existing.id != selectedTabID, !existing.model.isProcessRunning,
        !telegram.retainsSession(existing.model),
        !existing.model.hasUnsubmittedInput, reusableTab() != nil
      {
        // Keep the suspended tab until Pi confirms the switch, so a rejected switch
        // still leaves its saved transcript available. No second process is started.
        suspendedTarget = existing
      } else {
        existing.model.refreshSessionMetadata()
        selectTab(existing.id)
        return
      }
    }
    // A thread is a persisted JSONL conversation, not a dedicated Pi process. switch_session
    // also rebuilds Pi's runtime for the target cwd, so this works across projects too.
    if let tab = reusableTab() {
      let previousProjectPath = tab.model.projectURL?.standardizedFileURL.path
      let previousPath = tab.requestedSessionPath ?? tab.model.currentSessionPath
      let previousCreatedAt = tab.createdAt
      let previousIsDraft = tab.isDraft
      let savedDraft = composerDrafts[projectPath]
      if let previousProjectPath, previousProjectPath != projectPath {
        if !previousPath.isEmpty && !previousIsDraft {
          rememberSession(previousPath, in: previousProjectPath)
        }
        if selectedTabByProject[previousProjectPath] == tab.id {
          selectedTabByProject.removeValue(forKey: previousProjectPath)
        }
      }
      if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
        tabs[index].requestedSessionPath = path
        tabs[index].createdAt = .now
        tabs[index].isDraft = false
      }
      tab.model.switchSession(path: path, in: projectURL) {
        [weak self, weak model = tab.model] switched in
        guard let self, let model,
          let index = self.tabs.firstIndex(where: { $0.model === model })
        else { return }
        if !switched {
          self.tabs[index].requestedSessionPath = previousPath.isEmpty ? nil : previousPath
          self.tabs[index].createdAt = previousCreatedAt
          self.tabs[index].isDraft = previousIsDraft
          if self.selectedTabID == self.tabs[index].id {
            model.composerText = ""
            if self.selectedTabByProject[projectPath] == tab.id {
              self.selectedTabByProject.removeValue(forKey: projectPath)
            }
            if let previousProjectPath {
              self.selectedTabByProject[previousProjectPath] = tab.id
              UserDefaults.standard.set(previousProjectPath, forKey: Self.activeProjectKey)
            }
          }
        } else if let suspendedTarget {
          self.observations.removeValue(forKey: suspendedTarget.id)
          self.streamingObservations.removeValue(forKey: suspendedTarget.id)
          self.sessionObservations.removeValue(forKey: suspendedTarget.id)
          self.composerDraftObservations.removeValue(forKey: suspendedTarget.id)
          self.idleProcessTasks.removeValue(forKey: suspendedTarget.id)?.cancel()
          self.lastUsedAt.removeValue(forKey: suspendedTarget.id)
          suspendedTarget.model.disconnect()
          self.tabs.removeAll { $0.id == suspendedTarget.id }
        }
      }
      if savedDraft?.sessionPath == path { tab.model.composerText = savedDraft?.text ?? "" }
      selectTab(tab.id)
      return
    }
    discardSelectedDraftIfEmpty()
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

  /// Refresh persisted session metadata after a remote task updates its conversation.
  func remoteSessionChanged(in projectURL: URL?, sessionPath: String) {
    guard let projectURL else { return }
    refreshSessionCatalog(for: projectURL)
    guard !sessionPath.isEmpty else { return }
    for tab in tabs
    where tab.model.projectURL?.standardizedFileURL == projectURL.standardizedFileURL {
      tab.model.refreshExternalTranscript(at: sessionPath)
    }
  }

  func remoteSessionUpdated(from source: AppModel) {
    for tab in tabs {
      tab.model.applyRemoteSessionSnapshot(from: source)
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

  /// Resolve remote input without changing the desktop selection. Both surfaces own the
  /// same tab/runtime for a persisted conversation, so there is only one JSONL writer.
  func taskModel(in projectURL: URL, sessionPath: String?) -> AppModel {
    if let sessionPath, let existing = model(forSessionPath: sessionPath),
      existing.projectURL?.standardizedFileURL == projectURL.standardizedFileURL
    {
      if !existing.isProcessRunning, case .disconnected = existing.connectionState {
        existing.resumeProcess(sessionPath: sessionPath, continueLastSession: false)
      }
      return existing
    }
    let model = AppModel(
      startupProjectURL: projectURL, continueLastSession: false,
      startupSessionPath: sessionPath, restoreLastProjectOnLaunch: false,
      remembersDesktopProject: false)
    addTab(
      model: model, requestedSessionPath: sessionPath, isDraft: sessionPath == nil,
      select: false)
    return model
  }

  func disconnectAll() {
    t3Bridge.stop()
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

  private func addTab(
    model: AppModel, requestedSessionPath: String?, isDraft: Bool, select: Bool = true
  ) {
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
    streamingObservations[tab.id] = Publishers.CombineLatest3(
      model.$isStreaming, model.$isCompacting, model.$isLoadingConfiguration
    )
    .map { $0 || $1 || $2 }
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
          guard let self, let model, let projectURL = model.projectURL else { return }
          // Switching projects temporarily clears the model's old catalog. Keep the target
          // project's cached sidebar entries until its own discovery finishes.
          if sessions.isEmpty && model.isLoadingConfiguration { return }
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
    if select { selectTab(tab.id, startProcessIfNeeded: false) }
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
    telegram.refreshDesktopSnapshots()
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

  private var remoteSubmissionHolds: [ObjectIdentifier: Int] = [:]

  func holdRemoteSubmission(_ model: AppModel) {
    let key = ObjectIdentifier(model)
    remoteSubmissionHolds[key, default: 0] += 1
  }

  func releaseRemoteSubmission(_ model: AppModel) {
    let key = ObjectIdentifier(model)
    if let count = remoteSubmissionHolds[key], count > 1 {
      remoteSubmissionHolds[key] = count - 1
    } else {
      remoteSubmissionHolds.removeValue(forKey: key)
    }
    remoteSelectionChanged()
  }

  private func hasRemoteSubmission(_ model: AppModel) -> Bool {
    remoteSubmissionHolds[ObjectIdentifier(model)] != nil
  }

  /// Apply the same process policy after a remote selection changes. Warm remote
  /// selections and the desktop selection are protected by suspendProcess's guard.
  func remoteSelectionChanged() {
    for tab in tabs where tab.id != selectedTabID { scheduleProcessSuspension(for: tab.id) }
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
    // Keep only the selected process and processes with active work. Historical threads
    // remain in the session catalog and can be opened in the selected process later.
    suspendProcess(for: id)
  }

  private func reusableTab() -> Tab? {
    tabs.first { tab in
      tab.id == selectedTabID
        && tab.model.isProcessRunning
        && tab.model.canReuseProcessForNewSession
        && !telegram.retainsSession(tab.model)
        && !hasRemoteSubmission(tab.model)
        && !tab.model.hasUnsubmittedInput
        && !extensionUI.hasPendingRequests(from: tab.model)
    }
  }

  private func trimProcessPool() {
    var liveCount = tabs.filter { $0.model.isProcessRunning }.count
    guard liveCount > Self.maximumLiveProcesses else { return }
    let candidates =
      tabs
      .filter {
        $0.id != selectedTabID && $0.model.isProcessRunning && !$0.model.isBusy
          && !telegram.keepsProcessWarm($0.model)
          && !hasRemoteSubmission($0.model)
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
      !telegram.keepsProcessWarm(tab.model),
      !hasRemoteSubmission(tab.model),
      tab.model.canRestartSafely,
      tab.model.queuedPrompts.isEmpty,
      !extensionUI.hasPendingRequests(from: tab.model)
    else { return }
    if let projectURL = tab.model.projectURL { refreshSessionCatalog(for: projectURL) }
    tab.model.suspendProcess()
  }

  private func discardSelectedDraftIfEmpty(except retainedID: UUID? = nil) {
    guard let id = selectedTabID, id != retainedID,
      let tab = tabs.first(where: { $0.id == id }), tab.isDraft,
      !tab.model.hasUserMessage, !tab.model.hasUnsubmittedInput, !tab.model.isBusy,
      !telegram.retainsSession(tab.model)
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
    if !model.isLoadingConfiguration, !model.currentSessionPath.isEmpty,
      let index = tabs.firstIndex(where: { $0.model === model })
    {
      tabs[index].requestedSessionPath = model.currentSessionPath
      if model.hasUserMessage { tabs[index].isDraft = false }
    }
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

import Combine
import Foundation

struct WorkspaceProject: Identifiable, Hashable {
  let url: URL

  var id: String { url.standardizedFileURL.path }
  var name: String { url.lastPathComponent }
}

@MainActor
final class WorkspaceModel: ObservableObject {
  struct Tab: Identifiable {
    let id: UUID
    let model: AppModel
    let requestedSessionPath: String?
    let createdAt: Date
    let isDraft: Bool
  }

  @Published private(set) var tabs: [Tab] = []
  @Published private(set) var projects: [WorkspaceProject] = []
  @Published private(set) var loadingSessionCatalogs: Set<String> = []
  @Published var selectedTabID: UUID?
  let extensionUI = ExtensionUIModel()

  private static let savedProjectsKey = "workspaceProjectPaths"
  private static let activeProjectKey = "workspaceActiveProjectPath"
  private static let archivedSessionsKey = "workspaceArchivedSessionPaths"
  private static let sessionCatalogsKey = "workspaceSessionCatalogs"
  private static let maximumLiveProcesses = 4
  private static let idleProcessLifetime: Duration = .seconds(10 * 60)
  private var observations: [UUID: AnyCancellable] = [:]
  private var streamingObservations: [UUID: AnyCancellable] = [:]
  private var sessionObservations: [UUID: AnyCancellable] = [:]
  private var selectedTabByProject: [String: UUID] = [:]
  private var sessionCatalogs: [String: [SessionItem]]
  private var sessionCatalogGenerations: [String: UUID] = [:]
  private var lastUsedAt: [UUID: Date] = [:]
  private var idleProcessTasks: [UUID: Task<Void, Never>] = [:]
  private var archivedSessionPaths: Set<String>

  init() {
    let defaults = UserDefaults.standard
    archivedSessionPaths = Set(defaults.stringArray(forKey: Self.archivedSessionsKey) ?? [])
    sessionCatalogs = Self.readSessionCatalogs(from: defaults)
    let savedPaths = defaults.stringArray(forKey: Self.savedProjectsKey) ?? []
    let fallbackPath = defaults.string(forKey: "lastProjectPath")
    let paths = savedPaths.isEmpty ? fallbackPath.map { [$0] } ?? [] : savedPaths
    projects = paths.compactMap(Self.validProject(path:))

    let activePath = defaults.string(forKey: Self.activeProjectKey)
    if let project = projects.first(where: { $0.id == activePath }) ?? projects.first {
      addTab(
        model: AppModel(startupProjectURL: project.url, continueLastSession: true),
        requestedSessionPath: nil,
        isDraft: false
      )
    } else {
      addTab(
        model: AppModel(restoreLastProjectOnLaunch: false), requestedSessionPath: nil,
        isDraft: false)
    }

    for project in projects { refreshSessionCatalog(for: project.url) }
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
    refreshSessionCatalog(for: project.url)
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
    discardSelectedDraftIfEmpty()
    addTab(
      model: AppModel(startupProjectURL: project.url, continueLastSession: true),
      requestedSessionPath: nil,
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
      idleProcessTasks.removeValue(forKey: tab.id)?.cancel()
      lastUsedAt.removeValue(forKey: tab.id)
    }
    tabs.removeAll { $0.model.projectURL?.standardizedFileURL.path == project.id }
    projects.removeAll { $0.id == project.id }
    selectedTabByProject.removeValue(forKey: project.id)
    sessionCatalogs.removeValue(forKey: project.id)
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
    addTab(
      model: AppModel(
        startupProjectURL: projectURL,
        continueLastSession: false,
        startupSessionPath: path
      ),
      requestedSessionPath: path,
      isDraft: false
    )
  }

  /// 保留给旧视图代码；现在选择目录只会加入工作区，不再关闭其他项目。
  func replaceProject(with projectURL: URL) {
    addProject(projectURL)
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

  private func addTab(model: AppModel, requestedSessionPath: String?, isDraft: Bool) {
    model.extensionUI = extensionUI
    let tab = Tab(
      id: UUID(), model: model, requestedSessionPath: requestedSessionPath, createdAt: .now,
      isDraft: isDraft)
    tabs.append(tab)
    observations[tab.id] = model.objectWillChange.sink { [weak self, weak model] _ in
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
    selectTab(tab.id)
  }

  private func selectTab(_ id: UUID) {
    let previousID = selectedTabID
    if id != previousID { discardSelectedDraftIfEmpty(except: id) }
    selectedTabID = id
    guard let selected = tabs.first(where: { $0.id == id }) else { return }

    idleProcessTasks.removeValue(forKey: id)?.cancel()
    lastUsedAt[id] = .now
    if !selected.model.isProcessRunning {
      selected.model.resumeProcess(
        sessionPath: selected.requestedSessionPath,
        continueLastSession: !selected.isDraft
      )
    }
    extensionUI.selectSource(selected.model)
    if let path = selected.model.projectURL?.standardizedFileURL.path {
      selectedTabByProject[path] = id
      UserDefaults.standard.set(path, forKey: Self.activeProjectKey)
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

  private func refreshSessionCatalog(for projectURL: URL) {
    let projectPath = projectURL.standardizedFileURL.path
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

  nonisolated private static func validProject(path: String) -> WorkspaceProject? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }
    return WorkspaceProject(url: URL(fileURLWithPath: path, isDirectory: true))
  }
}

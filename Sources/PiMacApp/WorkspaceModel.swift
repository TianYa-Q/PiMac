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
  @Published var selectedTabID: UUID?
  let extensionUI = ExtensionUIModel()

  private static let savedProjectsKey = "workspaceProjectPaths"
  private static let activeProjectKey = "workspaceActiveProjectPath"
  private static let archivedSessionsKey = "workspaceArchivedSessionPaths"
  private var observations: [UUID: AnyCancellable] = [:]
  private var selectedTabByProject: [String: UUID] = [:]
  private var archivedSessionPaths: Set<String>

  init() {
    let defaults = UserDefaults.standard
    archivedSessionPaths = Set(defaults.stringArray(forKey: Self.archivedSessionsKey) ?? [])
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
    }
    selectProject(project)
  }

  func selectProject(_ project: WorkspaceProject) {
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
    }
    tabs.removeAll { $0.model.projectURL?.standardizedFileURL.path == project.id }
    projects.removeAll { $0.id == project.id }
    selectedTabByProject.removeValue(forKey: project.id)
    persistProjects()

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

  func sessions(in projectURL: URL) -> [SessionItem] {
    let projectPath = projectURL.standardizedFileURL.path
    var merged: [String: SessionItem] = [:]
    for tab in tabs where tab.model.projectURL?.standardizedFileURL.path == projectPath {
      for session in tab.model.sessions {
        if let previous = merged[session.path], previous.modifiedAt >= session.modifiedAt {
          continue
        }
        merged[session.path] = session
      }
      let path = tab.model.currentSessionPath
      if !path.isEmpty, tab.model.hasUserMessage, merged[path] == nil {
        let firstPrompt = tab.model.messages.first(where: { $0.kind == .user })?.text
        let title =
          tab.model.sessionName.isEmpty
          ? String((firstPrompt ?? "未命名会话").prefix(70)) : tab.model.sessionName
        merged[path] = SessionItem(path: path, title: title, modifiedAt: tab.createdAt)
      }
    }
    return merged.values
      .filter { !archivedSessionPaths.contains($0.path) }
      .sorted { $0.modifiedAt > $1.modifiedAt }
  }

  func archiveSession(path: String, in projectURL: URL) {
    guard model(forSessionPath: path)?.isStreaming != true else { return }
    archivedSessionPaths.insert(path)
    persistArchivedSessions()

    let removed = tabs.filter {
      $0.requestedSessionPath == path || $0.model.currentSessionPath == path
    }
    let removedIDs = Set(removed.map(\.id))
    let removedSelectedTab = selectedTabID.map(removedIDs.contains) ?? false
    for tab in removed {
      tab.model.disconnect()
      observations.removeValue(forKey: tab.id)
    }
    tabs.removeAll { removedIDs.contains($0.id) }

    guard removedSelectedTab else {
      objectWillChange.send()
      return
    }
    let projectPath = projectURL.standardizedFileURL.path
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
    selectTab(tab.id)
  }

  private func selectTab(_ id: UUID) {
    if id != selectedTabID { discardSelectedDraftIfEmpty(except: id) }
    selectedTabID = id
    guard let path = tabs.first(where: { $0.id == id })?.model.projectURL?.standardizedFileURL.path
    else { return }
    selectedTabByProject[path] = id
    UserDefaults.standard.set(path, forKey: Self.activeProjectKey)
  }

  private func discardSelectedDraftIfEmpty(except retainedID: UUID? = nil) {
    guard let id = selectedTabID, id != retainedID,
      let tab = tabs.first(where: { $0.id == id }), tab.isDraft,
      !tab.model.hasUserMessage, !tab.model.isStreaming
    else { return }
    tab.model.discardEmptyDraft()
    observations.removeValue(forKey: id)
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

  private func persistProjects() {
    UserDefaults.standard.set(projects.map(\.id), forKey: Self.savedProjectsKey)
  }

  private func persistArchivedSessions() {
    UserDefaults.standard.set(Array(archivedSessionPaths), forKey: Self.archivedSessionsKey)
  }

  nonisolated private static func validProject(path: String) -> WorkspaceProject? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }
    return WorkspaceProject(url: URL(fileURLWithPath: path, isDirectory: true))
  }
}

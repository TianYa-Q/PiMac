import Combine
import Foundation

@MainActor
final class WorkspaceModel: ObservableObject {
  struct Tab: Identifiable {
    let id: UUID
    let model: AppModel
    let requestedSessionPath: String?
    let createdAt: Date
  }

  @Published private(set) var tabs: [Tab] = []
  @Published var selectedTabID: UUID?

  private var observations: [UUID: AnyCancellable] = [:]

  init() {
    addTab(model: AppModel(), requestedSessionPath: nil)
  }

  var selectedModel: AppModel? {
    tabs.first(where: { $0.id == selectedTabID })?.model
  }

  func newSession(in projectURL: URL) {
    addTab(
      model: AppModel(startupProjectURL: projectURL, continueLastSession: false),
      requestedSessionPath: nil
    )
  }

  func openSession(path: String, in projectURL: URL) {
    if let existing = tabs.first(where: {
      $0.requestedSessionPath == path || $0.model.currentSessionPath == path
    }) {
      existing.model.refreshSessionMetadata()
      selectedTabID = existing.id
      return
    }
    addTab(
      model: AppModel(
        startupProjectURL: projectURL,
        continueLastSession: false,
        startupSessionPath: path
      ),
      requestedSessionPath: path
    )
  }

  func replaceProject(with projectURL: URL) {
    disconnectAll()
    tabs.removeAll()
    observations.removeAll()
    addTab(
      model: AppModel(startupProjectURL: projectURL, continueLastSession: true),
      requestedSessionPath: nil
    )
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
      if !path.isEmpty, merged[path] == nil {
        let firstPrompt = tab.model.messages.first(where: { $0.kind == .user })?.text
        let title =
          tab.model.sessionName.isEmpty
          ? String((firstPrompt ?? "未命名会话").prefix(70)) : tab.model.sessionName
        merged[path] = SessionItem(path: path, title: title, modifiedAt: tab.createdAt)
      }
    }
    return merged.values.sorted { $0.modifiedAt > $1.modifiedAt }
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
      tab.model.disconnect()
    }
  }

  private func addTab(model: AppModel, requestedSessionPath: String?) {
    let tab = Tab(
      id: UUID(), model: model, requestedSessionPath: requestedSessionPath, createdAt: .now)
    tabs.append(tab)
    observations[tab.id] = model.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    selectedTabID = tab.id
  }
}

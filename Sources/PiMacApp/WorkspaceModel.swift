import Combine
import Foundation

@MainActor
final class WorkspaceModel: ObservableObject {
  struct Tab: Identifiable {
    let id: UUID
    let model: AppModel
    let requestedSessionPath: String?
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
    let tab = Tab(id: UUID(), model: model, requestedSessionPath: requestedSessionPath)
    tabs.append(tab)
    observations[tab.id] = model.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    selectedTabID = tab.id
  }
}

import Combine
import Testing

@testable import PiMacApp

@MainActor
struct SidebarPerformanceTests {
  @Test func transcriptAndDiagnosticUpdatesDoNotInvalidateWorkspace() {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    var updates = 0
    let observation = WorkspaceModel.sidebarUpdates(for: model).sink { updates += 1 }
    defer { observation.cancel() }
    let initial = updates

    for index in 0..<100 {
      model.diagnosticText = "log \(index)"
      model.messages = [ChatEntry(id: "stream", kind: .assistant, title: "Pi", text: "\(index)")]
    }
    #expect(updates == initial)

    model.isStreaming = true
    model.isStreaming = true
    #expect(updates == initial + 1)
    model.currentSessionPath = "/tmp/session.jsonl"
    model.sessionName = "New title"
    #expect(updates == initial + 3)
  }

  @Test func unavailableProcessCannotBeReusedOrClearCurrentDraft() {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.composerText = "Keep this draft"
    model.connectionState = .connecting
    model.isLoadingConfiguration = true
    #expect(!model.canReuseProcessForNewSession)
    var result: Bool?
    model.newSession { result = $0 }
    #expect(result == false)
    #expect(model.composerText == "Keep this draft")
  }
}

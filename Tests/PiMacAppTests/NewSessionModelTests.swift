import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct NewSessionModelTests {
  @Test func newTasksUseLastExplicitSelectionEvenFromAnotherSession() {
    let suite = "PiMacApp.NewSessionModelTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("openai-codex/gpt-6-sol", forKey: "lastSelectedModelID")

    #expect(
      AppModel.preferredNewSessionModelID(
        currentModelID: "other/astra", defaults: defaults
      ) == "openai-codex/gpt-6-sol"
    )
  }

  @Test func newTasksKeepCurrentModelBeforeFirstExplicitSelection() {
    let suite = "PiMacApp.NewSessionModelTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(
      AppModel.preferredNewSessionModelID(
        currentModelID: "openai-codex/gpt-6-sol", defaults: defaults
      ) == "openai-codex/gpt-6-sol"
    )
    #expect(AppModel.preferredNewSessionModelID(currentModelID: "", defaults: defaults) == nil)
  }

}

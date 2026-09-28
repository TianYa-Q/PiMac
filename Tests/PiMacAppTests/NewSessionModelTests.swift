import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct NewSessionModelTests {
  @Test func newTasksUseConfiguredDefaultInsteadOfLastSelection() {
    let suite = "PiMacApp.NewSessionModelTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("other/last", forKey: "lastSelectedModelID")
    defaults.set("openai-codex/gpt-6-sol", forKey: "defaultNewSessionModelID")

    #expect(
      AppModel.preferredNewSessionModelID(
        currentModelID: "other/astra", defaults: defaults
      ) == "openai-codex/gpt-6-sol"
    )
  }

  @Test func unsetDefaultDoesNotReuseCurrentOrLegacySelection() {
    let suite = "PiMacApp.NewSessionModelTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("other/last", forKey: "lastSelectedModelID")

    #expect(
      AppModel.preferredNewSessionModelID(
        currentModelID: "openai-codex/gpt-6-sol", defaults: defaults
      ) == nil
    )
    #expect(AppModel.preferredNewSessionModelID(currentModelID: "", defaults: defaults) == nil)
  }

  @Test func malformedDefaultIsIgnored() {
    let suite = "PiMacApp.NewSessionModelTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    for value in ["", "model", "/model", "provider/"] {
      defaults.set(value, forKey: "defaultNewSessionModelID")
      #expect(AppModel.preferredNewSessionModelID(currentModelID: "other/model", defaults: defaults) == nil)
    }
  }
}

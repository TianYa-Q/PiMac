import Foundation
import Testing
@testable import PiMacApp

@MainActor struct TextGenerationModelSettingsTests {
  private let selected = TextGenerationModelSettings(status: .selected,
    selection: .init(instanceId: "pi", model: "anthropic/sonnet"),
    candidates: [.init(id: "anthropic/sonnet", name: "Sonnet")])

  @Test func decodeValidEmptyButRejectUnknownAndInconsistentStates() throws {
    let empty = try JSONDecoder().decode(TextGenerationModelSettings.self,
      from: Data(#"{"status":"no-visible-models","selection":null,"candidates":[]}"#.utf8))
    #expect(empty.status == .noVisibleModels)
    for json in [
      #"{"status":"unknown","selection":null,"candidates":[]}"#,
      #"{"status":"selected","selection":{"instanceId":"codex","model":"x"},"candidates":[]}"#,
      #"{"status":"selected","selection":{"instanceId":"pi","model":"a/b"},"candidates":[]}"#,
      #"{"status":"no-visible-models","selection":null,"candidates":[{"id":"a/b","name":"B"}]}"#,
      #"{"status":"selected","selection":{"instanceId":"pi","model":"a/b"},"candidates":[{"id":"a/b","name":"B"},{"id":"a/b","name":"B"}]}"#,
    ] {
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(TextGenerationModelSettings.self, from: Data(json.utf8))
      }
    }
  }

  @Test func saveFailureRetainsConfirmedOfficialSnapshotAndCanRetry() async {
    let store = TextGenerationModelStore()
    await store.update { selected }
    await store.update { throw CocoaError(.fileWriteNoPermission) }
    #expect(store.snapshot == selected)
    #expect(!store.error.isEmpty)
    #expect(!store.busy)
    let empty = TextGenerationModelSettings(status: .noVisibleModels, selection: nil, candidates: [])
    await store.update { empty }
    #expect(store.snapshot == empty)
    #expect(store.error.isEmpty)
    store.reset()
    #expect(store.snapshot == nil)
  }

  @Test func resetDiscardsOldServerResponse() async {
    let store = TextGenerationModelStore()
    await store.update {
      store.reset()
      return selected
    }
    #expect(store.snapshot == nil)
    #expect(!store.busy)
  }
}

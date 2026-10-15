import Foundation
import Testing

@testable import PiMacApp

@MainActor struct TextGenerationModelSettingsTests {
  private let selected = TextGenerationModelSettings(
    status: .selected,
    selection: .init(instanceId: "pi", model: "anthropic/sonnet"),
    candidates: [.init(id: "anthropic/sonnet", name: "Sonnet")])

  @Test func decodeValidEmptyButRejectUnknownAndInconsistentStates() throws {
    let empty = try JSONDecoder().decode(
      TextGenerationModelSettings.self,
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
    await store.update(refresh: true) { selected }
    await store.update(refresh: false) { throw CocoaError(.fileWriteNoPermission) }
    #expect(store.snapshot == selected)
    #expect(!store.error.isEmpty)
    #expect(!store.busy)
    let empty = TextGenerationModelSettings(
      status: .noVisibleModels, selection: nil, candidates: [])
    await store.update(refresh: true) { empty }
    #expect(store.snapshot == empty)
    #expect(store.error.isEmpty)
    store.reset()
    #expect(store.snapshot == nil)
  }

  @Test(arguments: [true, false])
  func refreshDuringReadOrSaveCoalescesAndNeverPublishesObsoleteResponse(refresh: Bool) async {
    let store = TextGenerationModelStore()
    let active = ResponseGate()
    let latest = ResponseGate()
    let task = Task { await store.update(refresh: refresh) { try await active.read() } }
    await active.waitUntilStarted()
    var supersededCalls = 0
    await store.update(refresh: true) {
      supersededCalls += 1
      return selected
    }
    await store.update(refresh: true) { try await latest.read() }
    active.finish(.success(selected))
    await latest.waitUntilStarted()
    #expect(store.snapshot == nil)
    #expect(store.busy)
    #expect(supersededCalls == 0)
    let empty = TextGenerationModelSettings(
      status: .noVisibleModels, selection: nil, candidates: [])
    latest.finish(.success(empty))
    await task.value
    #expect(store.snapshot == empty)
    #expect(!store.busy)
    #expect(store.error.isEmpty)
  }

  @Test func queuedRefreshRunsAfterFailureAndResetDiscardsOldGeneration() async {
    let store = TextGenerationModelStore()
    let active = ResponseGate()
    let latest = ResponseGate()
    let task = Task { await store.update(refresh: true) { try await active.read() } }
    await active.waitUntilStarted()
    await store.update(refresh: true) { try await latest.read() }
    active.finish(.failure(CocoaError(.fileReadUnknown)))
    await latest.waitUntilStarted()
    #expect(store.busy)
    #expect(store.error.isEmpty)
    latest.finish(.success(selected))
    await task.value
    #expect(store.snapshot == selected)

    let old = ResponseGate()
    let reconnected = ResponseGate()
    let oldTask = Task { await store.update(refresh: false) { try await old.read() } }
    await old.waitUntilStarted()
    var discardedCalls = 0
    await store.update(refresh: true) {
      discardedCalls += 1
      return selected
    }
    store.reset()
    let newTask = Task { await store.update(refresh: true) { try await reconnected.read() } }
    await reconnected.waitUntilStarted()
    old.finish(.success(selected))
    await oldTask.value
    #expect(store.snapshot == nil)
    #expect(store.busy)
    #expect(discardedCalls == 0)
    reconnected.finish(.failure(CocoaError(.fileReadNoPermission)))
    await newTask.value
    #expect(store.snapshot == nil)
    #expect(!store.busy)
    #expect(!store.error.isEmpty)
  }

  /// 用 continuation 精确控制服务响应，不依赖 sleep 或调度顺序猜测。
  @MainActor private final class ResponseGate {
    private var response: CheckedContinuation<TextGenerationModelSettings, Error>?
    private var started: CheckedContinuation<Void, Never>?

    func read() async throws -> TextGenerationModelSettings {
      try await withCheckedThrowingContinuation { continuation in
        response = continuation
        started?.resume()
        started = nil
      }
    }

    func waitUntilStarted() async {
      if response != nil { return }
      await withCheckedContinuation { started = $0 }
    }

    func finish(_ result: Result<TextGenerationModelSettings, Error>) {
      response?.resume(with: result)
      response = nil
    }
  }
}

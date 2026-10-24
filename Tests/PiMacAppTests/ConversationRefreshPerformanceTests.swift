import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ConversationRefreshPerformanceTests {
  @Test func unrelatedGlobalEventsDoNotInvalidateUnchangedHistory() throws {
    let before: [String: Any] = [
      "snapshotSequence": 10,
      "projection": ["visibleTurnItems": [["item": ["id": "inherited", "text": "old"]]]],
      "hasMoreHistory": false,
    ]
    var otherThreadAdvanced = before
    otherThreadAdvanced["snapshotSequence"] = 11
    #expect(
      try T3DesktopClient.snapshotFingerprint(before)
        == T3DesktopClient.snapshotFingerprint(otherThreadAdvanced))
    var changed = before
    changed["projection"] = [
      "visibleTurnItems": [["item": ["id": "inherited", "text": "new"]]]
    ]
    #expect(
      try T3DesktopClient.snapshotFingerprint(before)
        != T3DesktopClient.snapshotFingerprint(changed))
    changed = before
    changed["hasMoreHistory"] = true
    #expect(
      try T3DesktopClient.snapshotFingerprint(before)
        != T3DesktopClient.snapshotFingerprint(changed))
  }

  @Test func threadIndexPreservesFirstMatchAndDropsRemovedRows() throws {
    let suite = "pimac-thread-index-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let rows: [[String: Any]] = [
      ["id": "same", "title": "first"], ["id": "same", "title": "second"],
      ["id": "removed", "title": "old"],
    ]
    defaults.set(
      try JSONSerialization.data(withJSONObject: ["threads": rows]),
      forKey: "t3DesktopShellCache")
    let client = T3DesktopClient(defaults: defaults)
    #expect(client.thread("same")?["title"] as? String == "first")
    #expect(client.thread("removed") != nil)
    client.applyShell(["threads": [["id": "same", "title": "updated"]]])
    #expect(client.thread("same")?["title"] as? String == "updated")
    #expect(client.thread("removed") == nil)
    #expect(client.thread("unknown") == nil)
  }

  @Test func concurrentLongHistoriesUseBackgroundProjectionWithoutLosingMessages() async throws {
    let count = 4_000
    let items: [[String: Any]] = (0..<count).map { index in
      [
        "item": [
          "id": "message-\(index)", "type": "assistant_message",
          "text": "历史消息 \(index)", "startedAt": "2026-10-24T00:00:01Z",
        ]
      ]
    }
    let snapshot = ImmutableJSONSnapshot(value: [
      "projection": [
        "thread": ["id": "thread"], "visibleTurnItems": items,
      ]
    ])
    let expected = T3V2Presentation.detail(snapshot.value)
    let started = ContinuousClock.now
    async let first = snapshot.presentedThread()
    async let second = snapshot.presentedThread()
    async let third = snapshot.presentedThread()
    async let fourth = snapshot.presentedThread()
    for result in try await [first, second, third, fourth] {
      #expect(NSDictionary(dictionary: result.value).isEqual(to: expected))
      let thread = try #require(result.value["thread"] as? [String: Any])
      #expect((thread["messages"] as? [[String: Any]])?.count == count)
    }
    print("Concurrent projection: 4 × \(count) messages, \(started.duration(to: .now))")
  }

  @Test func indexedLookupDoesNotScaleWithEverySidebarRow() throws {
    let suite = "pimac-index-benchmark-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let client = T3DesktopClient(defaults: defaults)
    let rows: [[String: Any]] = (0..<4_000).map { ["id": "thread-\($0)"] }
    client.applyShell(["threads": rows])
    let started = ContinuousClock.now
    for index in 0..<4_000 {
      #expect(client.thread("thread-\(index)")?["id"] as? String == "thread-\(index)")
    }
    print("Indexed lookup: 4000 threads × 4000 lookups, \(started.duration(to: .now))")
  }
}

import Foundation
import Testing

@testable import PiMacApp

struct SessionSwitchPerformanceTests {
  private func entry(_ id: String, kind: ChatEntryKind = .user, text: String = "hello") -> ChatEntry
  {
    ChatEntry(id: id, kind: kind, title: "", text: text)
  }

  @Test @MainActor
  func cacheInvalidatesChangedFilesAndKeepsOnlyOneVersion() {
    let cache = TranscriptCache()
    cache.insert([entry("old")], at: "/a", key: "v1")
    #expect(cache.entries(at: "/a", key: "v1")?.first?.id == "old")
    #expect(cache.entries(at: "/a", key: "v2") == nil)
    #expect(cache.totalBytes == 0)
    cache.insert([entry("new")], at: "/a", key: "v2")
    #expect(cache.entries(at: "/a", key: "v2")?.first?.id == "new")
  }

  @Test @MainActor
  func cacheEvictsLeastRecentlyUsedSession() {
    let cache = TranscriptCache(maximumSessions: 2)
    cache.insert([entry("a")], at: "/a", key: "1")
    cache.insert([entry("b")], at: "/b", key: "1")
    _ = cache.entries(at: "/a", key: "1")
    cache.insert([entry("c")], at: "/c", key: "1")
    #expect(cache.entries(at: "/b", key: "1") == nil)
    #expect(cache.entries(at: "/a", key: "1") != nil)
    #expect(cache.entries(at: "/c", key: "1") != nil)
  }

  @Test @MainActor
  func cacheEnforcesByteBudgetAndSkipsOversizedHistory() {
    let cache = TranscriptCache(maximumBytes: 600)
    cache.insert([entry("a")], at: "/a", key: "1")
    cache.insert([entry("b")], at: "/b", key: "1")
    cache.insert([entry("c")], at: "/c", key: "1")
    #expect(cache.totalBytes <= 600)
    #expect(cache.entries(at: "/a", key: "1") == nil)
    cache.insert([entry("large", text: String(repeating: "x", count: 1000))], at: "/c", key: "2")
    #expect(cache.entries(at: "/c", key: "2") == nil)
    #expect(cache.totalBytes <= 600)
  }

  @Test @MainActor
  func groupingUpdatesAfterInPlaceMutationAndSessionReplacement() {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.messages = [entry("user"), entry("answer", kind: .assistant)]
    let first = model.conversationTurns
    #expect(model.conversationTurns == first)
    // Configuration/status updates must leave the prepared display data unchanged.
    model.statusText = "refresh"
    #expect(model.conversationTurns == first)
    model.messages[1].text = "updated"
    #expect(model.conversationTurns[0].finalAssistant?.text == "updated")
    #expect(first[0].finalAssistant?.text == "hello")
    model.messages = [entry("next")]
    #expect(model.conversationTurns.map(\.id) == ["next"])
    model.messages.removeAll()
    #expect(model.conversationTurns.isEmpty)
  }

  @Test
  func groupingPreservesActivityAndSupplementaryEntries() {
    let messages = [
      entry("system", kind: .system), entry("user"),
      entry("thinking", kind: .thinking), entry("intermediate", kind: .assistant),
      entry("tool", kind: .tool), entry("final", kind: .assistant),
      entry("compact", kind: .compaction), entry("next"),
    ]
    let turns = ConversationTurn.group(messages)
    #expect(turns.map(\.id) == ["system", "user", "next"])
    #expect(turns[1].activity.map(\.id) == ["thinking", "intermediate", "tool"])
    #expect(turns[1].finalAssistant?.id == "final")
    #expect(turns[1].supplementaryEntries.map(\.id) == ["compact"])
    #expect(turns.flatMap(\.entries) == messages)
  }

  @Test @MainActor
  func reopeningUnchangedSessionUsesPreparedDiskSnapshot() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let record: PiRPCClient.JSON = [
      "type": "message", "id": "user", "parentId": NSNull(),
      "message": ["role": "user", "content": "cached history"],
    ]
    try JSONSerialization.data(withJSONObject: record).write(to: url)
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.currentSessionPath = url.path
    model.refreshExternalTranscript(at: url.path)
    for _ in 0..<100 where model.messages.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.messages.count == 1)
    let reopened = AppModel(restoreLastProjectOnLaunch: false)
    reopened.currentSessionPath = url.path
    reopened.refreshExternalTranscript(at: url.path)
    // No actor turn or disk parser wait is needed for an unchanged history.
    #expect(reopened.messages == model.messages)
  }
}

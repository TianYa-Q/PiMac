import Foundation
import Testing

@testable import PiMacApp

struct T3StreamReducerTests {
  @Test func officialShellReducerValidatesOrdersAndResetsSnapshots() async throws {
    let reducer = T3StreamReducer(kind: .shell)
    let initial = ImmutableJSONSnapshot(value: [
      "kind": "snapshot",
      "snapshot": [
        "schemaVersion": 1, "snapshotSequence": 4, "threads": [], "archivedThreads": [],
        "projects": [],
      ],
    ])
    #expect(try await reducer.apply(initial))
    #expect(try await reducer.snapshot().value["snapshotSequence"] as? Int == 4)
    let removed = ImmutableJSONSnapshot(value: [
      "kind": "thread.removed", "sequence": 7, "location": "active", "threadId": "gone",
    ])
    #expect(try await reducer.apply(removed))
    #expect(try await reducer.snapshot().value["snapshotSequence"] as? Int == 7)
    #expect(try await !reducer.apply(removed))
    #expect(try await !reducer.apply(ImmutableJSONSnapshot(value: ["kind": "synchronized"])))
    // 全局序号允许跳跃；新连接的权威快照也不能被上一连接的序号挡住。
    #expect(try await reducer.apply(initial))
    #expect(try await reducer.snapshot().value["snapshotSequence"] as? Int == 4)
    await #expect(throws: T3StreamReducer.Failure.self) {
      try await reducer.apply(ImmutableJSONSnapshot(value: ["kind": "thread.removed"]))
    }
    #expect(try await reducer.snapshot().value["snapshotSequence"] as? Int == 4)
  }

  @Test func invalidFramesCannotBecomeAnEmptyConversation() async throws {
    let reducer = T3StreamReducer(kind: .thread)
    await #expect(throws: T3StreamReducer.Failure.self) {
      try await reducer.apply(
        ImmutableJSONSnapshot(value: [
          "kind": "snapshot", "snapshotSequence": 1, "projection": [:],
        ]))
    }
    await #expect(throws: T3StreamReducer.Failure.self) { try await reducer.snapshot() }
  }

  @MainActor @Test func hiddenShellUpdatesStatusWithoutErasingHistory() {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.currentSessionPath = "t3:one"
    model.apply([
      "thread": [
        "id": "one", "messages": [["id": "m", "role": "user", "text": "保留正文"]],
      ]
    ])
    model.setConversationVisible(false)
    model.applyBackgroundThreadState([
      "id": "one", "title": "New title", "latestTurn": ["turnId": "run", "state": "running"],
    ])
    #expect(model.isStreaming)
    #expect(model.messages.map(\.text) == ["保留正文"])
    model.applyBackgroundThreadState([
      "id": "different", "latestTurn": ["turnId": "run", "state": "completed"],
    ])
    #expect(model.isStreaming)
    model.applyBackgroundThreadState([
      "id": "one", "latestTurn": ["turnId": "run", "state": "completed"],
    ])
    #expect(!model.isStreaming)
    #expect(model.messages.map(\.text) == ["保留正文"])
    model.setConversationVisible(true)
    model.applyBackgroundThreadState([
      "id": "one", "latestTurn": ["turnId": "next", "state": "running"],
    ])
    #expect(!model.isStreaming, "可见标签由正文订阅负责，不接受轻量 shell 覆盖")
    model.disconnect()
  }

  @MainActor @Test func lateShellHTTPResponseCannotRollBackLiveEvents() throws {
    let suite = "shell-sequence-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let client = T3DesktopClient(defaults: defaults)
    defer {
      client.stop()
      defaults.removePersistentDomain(forName: suite)
    }
    client.applyShell(["snapshotSequence": 7, "threads": [["id": "one", "title": "New"]]])
    client.applyShell(["snapshotSequence": 4, "threads": [["id": "one", "title": "Old"]]])
    #expect(client.thread("one")?["title"] as? String == "New")
    client.stop()
    client.applyShell(["snapshotSequence": 1, "threads": [["id": "one", "title": "Reset"]]])
    #expect(client.thread("one")?["title"] as? String == "Reset")
  }
}

import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct HistoryPagingTests {
  private let date = "2026-11-05T00:00:00Z"

  private func item(_ id: String, ordinal: Int, text: String) -> [String: Any] {
    [
      "id": id, "threadId": "one", "runId": NSNull(), "nodeId": NSNull(),
      "providerThreadId": NSNull(), "providerTurnId": NSNull(), "nativeItemRef": NSNull(),
      "parentItemId": NSNull(), "ordinal": ordinal, "status": "completed", "title": NSNull(),
      "startedAt": date, "completedAt": date, "updatedAt": date,
      "type": "assistant_message", "messageId": "message-\(id)", "text": text, "streaming": false,
    ]
  }

  private func row(_ item: [String: Any], position: Int) -> [String: Any] {
    [
      "position": position, "visibility": "local", "sourceThreadId": "one",
      "sourceItemId": item["id"]!, "item": item,
    ]
  }

  private func snapshot() -> ImmutableJSONSnapshot {
    var projection: [String: Any] = [
      "thread": [
        "id": "one", "projectId": "project", "title": "Bounded history",
        "createdBy": "user", "creationSource": "web", "providerInstanceId": "pi",
        "modelSelection": ["instanceId": "pi", "model": "test"],
        "runtimeMode": "full-access", "interactionMode": "default",
        "branch": NSNull(), "worktreePath": NSNull(), "activeProviderThreadId": NSNull(),
        "lineage": [
          "parentThreadId": NSNull(), "relationshipToParent": NSNull(), "rootThreadId": "one",
        ],
        "forkedFrom": NSNull(), "createdAt": date, "updatedAt": date,
        "archivedAt": NSNull(), "deletedAt": NSNull(),
      ],
      "updatedAt": date,
    ]
    for key in [
      "runs", "attempts", "nodes", "subagents", "providerSessions", "providerThreads",
      "runtimeRequests", "messages", "plans", "providerTurns", "turnItems", "checkpointScopes",
      "checkpoints", "contextHandoffs", "contextTransfers", "visibleTurnItems",
    ] {
      projection[key] = [Any]()
    }
    let recent = item("recent", ordinal: 100, text: "近期正文")
    projection["visibleTurnItems"] = [row(recent, position: 0)]
    // 覆盖官方 compact 恢复函数，宿主不能把省略字段直接当作完整投影。
    return ImmutableJSONSnapshot(value: [
      "kind": "snapshot", "snapshotSequence": 10, "projection": projection,
      "historyCursor": "older", "hasMoreHistory": true, "latestLocalTurnOrdinal": 100,
      "turnItemsOmitLocalVisible": true,
    ])
  }

  @Test func olderPagesMergeWithoutOverwritingLiveUpdatesOrSequence() async throws {
    let reducer = T3StreamReducer(kind: .thread)
    #expect(try await reducer.apply(snapshot()))
    let initial = try await reducer.snapshot().value
    let revision = try #require(initial["historyRevision"] as? Int)
    let projection = try #require(initial["projection"] as? [String: Any])
    #expect((projection["turnItems"] as? [[String: Any]])?.count == 1)
    let updated = item("recent", ordinal: 100, text: "实时新正文")
    #expect(
      try await reducer.apply(
        ImmutableJSONSnapshot(value: [
          "kind": "event", "sequence": 12,
          "event": [
            "id": "update", "type": "turn-item.updated", "threadId": "one",
            "occurredAt": date, "payload": updated,
          ],
        ])))
    // 显式 HTTP 刷新的迟到快照也不能回滚订阅已应用的新事件。
    #expect(try await reducer.apply(snapshot(), preservingLiveSequence: true) == false)
    // 历史响应包含重叠旧版本；官方合并必须以实时状态为准，并按身份去重。
    let older = row(item("old", ordinal: 1, text: "旧正文"), position: 0)
    let stale = row(item("recent", ordinal: 100, text: "过时正文"), position: 1)
    let page = ImmutableJSONSnapshot(value: [
      "snapshotSequence": 10, "items": [older, older, stale],
      "nextCursor": NSNull(), "hasMoreHistory": false,
    ])
    #expect(try await reducer.mergeHistory(page, cursor: "older", revision: revision))
    let merged = try await reducer.snapshot().value
    #expect(merged["snapshotSequence"] as? Int == 12)
    #expect(merged["hasMoreHistory"] as? Bool == false)
    #expect(merged["historyExpanded"] as? Bool == true)
    let detail = T3V2Presentation.detail(merged)
    #expect(detail["historyExpanded"] as? Bool == true)
    let messages = (detail["thread"] as? [String: Any])?["messages"] as? [[String: Any]]
    #expect(messages?.compactMap { $0["text"] as? String } == ["旧正文", "实时新正文"])
    #expect(try await reducer.mergeHistory(page, cursor: "older", revision: revision) == false)
  }

  @Test func newSnapshotsRejectLatePagesEvenWithTheSameCursorAndInvalidPagesDoNotAdvance()
    async throws
  {
    let reducer = T3StreamReducer(kind: .thread)
    _ = try await reducer.apply(snapshot())
    let revision = try #require(try await reducer.snapshot().value["historyRevision"] as? Int)
    let corrupt = ImmutableJSONSnapshot(value: ["items": []])
    await #expect(throws: T3StreamReducer.Failure.self) {
      try await reducer.mergeHistory(corrupt, cursor: "older", revision: revision)
    }
    #expect(try await reducer.snapshot().value["historyCursor"] as? String == "older")
    _ = try await reducer.apply(snapshot())
    let page = ImmutableJSONSnapshot(value: [
      "snapshotSequence": 10, "items": [row(item("old", ordinal: 1, text: "旧正文"), position: 0)],
      "nextCursor": NSNull(), "hasMoreHistory": false,
    ])
    #expect(try await reducer.mergeHistory(page, cursor: "older", revision: revision) == false)
    // 落在窗口之前、且未加载的旧 item 更新不能把很久前的正文重新插回近期窗口。
    #expect(
      try await reducer.apply(
        ImmutableJSONSnapshot(value: [
          "kind": "event", "sequence": 11,
          "event": [
            "id": "old-update", "type": "turn-item.updated", "threadId": "one",
            "occurredAt": date, "payload": item("old", ordinal: 1, text: "旧正文更新"),
          ],
        ])) == false)
    let state = try await reducer.snapshot().value
    let projection = try #require(state["projection"] as? [String: Any])
    #expect((projection["visibleTurnItems"] as? [[String: Any]])?.count == 1)
  }

  @Test func recentCacheDoesNotRetainLongTranscripts() throws {
    let suite = "history-cache-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let project = URL(fileURLWithPath: "/tmp/pimac-history-cache")
    let cache = ConversationPresentationCache(defaults: defaults)
    cache.store(
      project: project, threadID: "one", title: "近期副本",
      messages: (0..<300).map {
        ChatEntry(id: "m\($0)", kind: .assistant, title: "Pi", text: "正文 \($0)")
      })
    cache.persist()
    let restored = ConversationPresentationCache(defaults: defaults).snapshot(
      project: project, threadID: "one")
    #expect(restored?.messages.count == 75)
    #expect(restored?.messages.first?.id == "m225")
    #expect(restored?.messages.last?.id == "m299")
  }

  @Test func historyFailureRemainsRetryableAndNewSessionsClearPagingState() async {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    defer { model.disconnect() }
    model.currentSessionPath = "t3:one"
    model.apply(["hasMoreHistory": true, "thread": ["id": "one", "messages": []]])
    await model.loadEarlierHistory()
    #expect(model.hasMoreHistory)
    #expect(model.historyError != nil)
    #expect(!model.isLoadingHistory)
    model.switchSession(path: "t3:other", in: URL(fileURLWithPath: "/tmp/pimac-history"))
    #expect(!model.hasMoreHistory)
    #expect(model.historyError == nil)
  }
}

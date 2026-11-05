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

  @MainActor @Test func speedAndCostSurviveOfficialStreamDecodingAndReachTheComposer() async throws {
    let reducer = T3StreamReducer(kind: .thread)
    let date = "2026-11-04T00:00:00Z"
    let metrics: [String: Any] = [
      "outputDurationMs": 10000, "speedMethod": "aa-approx-v1",
      "speedTokens": 180, "speedDurationMs": 2000, "totalCostUsd": 0.012,
    ]
    var turn: [String: Any] = [
      "id": "turn", "providerThreadId": "provider", "nodeId": "node",
      "runAttemptId": NSNull(), "nativeTurnRef": NSNull(), "ordinal": 1,
      "status": "completed", "startedAt": date, "completedAt": date,
      "turnTokenUsage": [
        "usageScope": "main_agent", "usageStatus": "complete", "hasSubagents": false,
        "inputTokens": 100, "outputTokens": 200,
      ],
      "piMetrics": metrics,
    ]
    var projection: [String: Any] = [
      "thread": [
        "id": "one", "projectId": "project", "title": "Token throughput",
        "createdBy": "user", "creationSource": "web", "providerInstanceId": "pi",
        "modelSelection": ["instanceId": "pi", "model": "test"],
        "runtimeMode": "full-access", "interactionMode": "default",
        "branch": NSNull(), "worktreePath": NSNull(), "activeProviderThreadId": NSNull(),
        "lineage": ["parentThreadId": NSNull(), "relationshipToParent": NSNull(), "rootThreadId": "one"],
        "forkedFrom": NSNull(), "createdAt": date, "updatedAt": date,
        "archivedAt": NSNull(), "deletedAt": NSNull(),
      ],
      "providerTurns": [turn], "updatedAt": date,
    ]
    for key in ["runs", "attempts", "nodes", "subagents", "providerSessions", "providerThreads",
      "runtimeRequests", "messages", "plans", "turnItems", "checkpointScopes", "checkpoints",
      "contextHandoffs", "contextTransfers", "visibleTurnItems"] {
      projection[key] = [Any]()
    }
    let snapshot = ImmutableJSONSnapshot(value: [
      "kind": "snapshot", "snapshotSequence": 1, "projection": projection,
    ])
    // 覆盖实际 JSC 协议解码与官方 reducer；直接把 JSON 交给展示层会漏掉字段被剥离的问题。
    #expect(try await reducer.apply(snapshot))
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.currentSessionPath = "t3:one"
    defer { model.disconnect() }
    func check(_ expected: Double) async throws {
      let decoded = try await reducer.snapshot()
      let stats = try #require(T3V2Presentation.stats(decoded.value))
      #expect(stats.outputTokensPerSecond == expected)
      #expect(stats.cost == 0.012)
      let detail = T3V2Presentation.detail(decoded.value)
      model.apply(detail)
      #expect(model.outputTokensPerSecond == expected)
    }
    try await check(90)
    turn["piMetrics"] = metrics.merging(["speedTokens": 240]) { _, new in new }
    #expect(try await reducer.apply(ImmutableJSONSnapshot(value: [
      "kind": "event", "sequence": 2,
      "event": ["id": "update", "type": "provider-turn.updated", "threadId": "one",
        "occurredAt": date, "payload": turn],
    ])))
    try await check(120)
    // 重连快照必须和增量事件使用同一协议，不能在刷新后又丢掉速度。
    #expect(try await reducer.apply(snapshot))
    try await check(90)
    var corrupt = metrics
    corrupt["speedDurationMs"] = -1
    turn["piMetrics"] = corrupt
    await #expect(throws: T3StreamReducer.Failure.self) {
      try await reducer.apply(ImmutableJSONSnapshot(value: [
        "kind": "event", "sequence": 3,
        "event": ["id": "bad", "type": "provider-turn.updated", "threadId": "one",
          "occurredAt": date, "payload": turn],
      ]))
    }
    try await check(90)
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

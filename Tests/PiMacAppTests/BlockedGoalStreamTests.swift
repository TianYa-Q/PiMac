import Foundation
import Testing

@testable import PiMacApp

struct BlockedGoalStreamTests {
  @MainActor @Test func reasonSurvivesOfficialSnapshotUpdatesAndReconnectWithoutCreatingAQuestion()
    async throws
  {
    let date = "2026-11-04T00:00:00Z"
    let reducer = T3StreamReducer(kind: .thread)
    var provider: [String: Any] = [
      "id": "provider", "driver": "pi", "providerInstanceId": "pi",
      "providerSessionId": NSNull(), "appThreadId": "one", "ownerNodeId": NSNull(),
      "nativeThreadRef": NSNull(), "nativeConversationHeadRef": NSNull(), "status": "idle",
      "firstRunOrdinal": NSNull(), "lastRunOrdinal": NSNull(), "handoffIds": [],
      "forkedFrom": NSNull(), "createdAt": date, "updatedAt": date,
      "goal": ["objective": "验证旧软件", "status": "blocked", "pauseReason": "请提供真实样例"],
    ]
    var projection: [String: Any] = [
      "thread": [
        "id": "one", "projectId": "project", "title": "Blocked goal",
        "createdBy": "user", "creationSource": "web", "providerInstanceId": "pi",
        "modelSelection": ["instanceId": "pi", "model": "test"],
        "runtimeMode": "full-access", "interactionMode": "default",
        "branch": NSNull(), "worktreePath": NSNull(), "activeProviderThreadId": "provider",
        "lineage": [
          "parentThreadId": NSNull(), "relationshipToParent": NSNull(), "rootThreadId": "one",
        ],
        "forkedFrom": NSNull(), "createdAt": date, "updatedAt": date,
        "archivedAt": NSNull(), "deletedAt": NSNull(),
      ],
      "providerThreads": [provider], "updatedAt": date,
    ]
    for key in [
      "runs", "attempts", "nodes", "subagents", "providerSessions", "providerTurns",
      "runtimeRequests", "messages", "plans", "turnItems", "checkpointScopes", "checkpoints",
      "contextHandoffs", "contextTransfers", "visibleTurnItems",
    ] {
      projection[key] = [Any]()
    }
    let snapshot = ImmutableJSONSnapshot(value: [
      "kind": "snapshot", "snapshotSequence": 1, "projection": projection,
    ])
    let model = AppModel(continueLastSession: false, restoreLastProjectOnLaunch: false)
    model.currentSessionPath = "t3:one"
    defer { model.disconnect() }
    func check(_ reason: String?) async throws {
      let decoded = try await reducer.snapshot()
      let value = try #require(decoded.value["projection"] as? [String: Any])
      #expect((value["runtimeRequests"] as? [Any])?.isEmpty == true)
      model.apply(T3V2Presentation.detail(decoded.value))
      guard case .available(let goal, driver: "pi") = model.goalState else {
        Issue.record("官方订阅未保留目标")
        return
      }
      #expect(goal.pauseReason == reason)
      #expect(goal.blockerDescription == reason)
    }
    #expect(try await reducer.apply(snapshot))
    try await check("请提供真实样例")
    provider["goal"] = [
      "objective": "验证旧软件", "status": "blocked", "pauseReason": "请提供 Windows 测试环境",
    ]
    #expect(
      try await reducer.apply(
        ImmutableJSONSnapshot(value: [
          "kind": "event", "sequence": 2,
          "event": [
            "id": "update", "type": "provider-thread.updated", "threadId": "one",
            "occurredAt": date, "payload": provider,
          ],
        ])))
    try await check("请提供 Windows 测试环境")
    #expect(try await reducer.apply(snapshot))
    try await check("请提供真实样例")
    provider["goal"] = ["objective": "验证旧软件", "status": "active"]
    #expect(
      try await reducer.apply(
        ImmutableJSONSnapshot(value: [
          "kind": "event", "sequence": 3,
          "event": [
            "id": "resume", "type": "provider-thread.updated", "threadId": "one",
            "occurredAt": date, "payload": provider,
          ],
        ])))
    try await check(nil)
  }
}

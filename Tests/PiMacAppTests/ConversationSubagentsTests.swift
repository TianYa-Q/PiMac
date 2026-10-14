import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ConversationSubagentsTests {
  private func thread(_ id: String, parent: String, status: String, date: String) -> [String: Any] {
    ["id": id, "title": "任务 \(id)", "status": status, "createdAt": date,
     "modelSelection": ["instanceId": "pi", "model": "test-model"],
     "lineage": ["relationshipToParent": "subagent", "parentThreadId": parent]]
  }

  @Test func onlyDirectDelegationIsShownAndDescendantWorkPropagates() {
    let child = thread("c", parent: "p", status: "completed", date: "2026-01-01T00:00:10Z")
    var fork = thread("f", parent: "p", status: "running", date: "2026-01-01T00:00:10Z")
    fork["lineage"] = ["relationshipToParent": "fork", "parentThreadId": "p"]
    let tasks = ConversationSubagent.children(parentID: "p", threads: [
      child, child, fork,
      thread("g", parent: "c", status: "waiting", date: "2026-01-01T00:00:20Z"),
      thread("p", parent: "p", status: "running", date: "2026-01-01T00:00:20Z"),
    ])
    #expect(tasks.map(\.id) == ["c"])
    #expect(tasks[0].status == .working)
    #expect(tasks[0].model == "pi · test-model")
  }

  @Test func statusChangesDoNotMoveOrDuplicateTimelineCards() {
    let messages = [
      ChatEntry(id: "u", kind: .user, title: "", text: "start",
        timestamp: T3DesktopClient.date("2026-01-01T00:00:00Z")),
      ChatEntry(id: "a", kind: .assistant, title: "", text: "delegating",
        timestamp: T3DesktopClient.date("2026-01-01T00:00:05Z")),
      ChatEntry(id: "b", kind: .assistant, title: "", text: "finished",
        timestamp: T3DesktopClient.date("2026-01-01T00:01:00Z")),
    ]
    for status in ["queued", "running", "completed", "failed", "cancelled"] {
      let children = ConversationSubagent.children(parentID: "p", threads: [
        thread("c", parent: "p", status: status, date: "2026-01-01T00:00:10Z"),
        thread("d", parent: "p", status: status, date: "2026-01-01T00:00:11Z"),
      ])
      let rows = ConversationTimelineRow.build(messages: messages, children: children)
      #expect(rows.map(\.id) == ["turn-u", "subagents-c", "turn-b"])
      guard case .subagents(let tasks) = rows[1] else { Issue.record("Missing card"); return }
      #expect(tasks.count == 2)
      guard case .turn(let before) = rows[0], case .turn(let after) = rows[2] else {
        Issue.record("Missing conversation"); return
      }
      #expect(before.finalAssistant?.id == "a")
      #expect(after.finalAssistant?.id == "b")
    }
  }

  @Test func elapsedTimeUsesRunStartUpdatesLiveAndFreezesAtCompletion() throws {
    let start = T3DesktopClient.date("2026-01-01T00:01:00Z")
    var native = thread("c", parent: "p", status: "running", date: "2026-01-01T00:00:00Z")
    native["latestRunStartedAt"] = "2026-01-01T00:01:00Z"
    // 运行中的下一轮可能仍带上一轮结束时间，不能让计时被冻结。
    native["latestRunCompletedAt"] = "2026-01-01T00:00:30Z"
    let working = try #require(ConversationSubagent.children(parentID: "p", threads: [native]).first)
    #expect(working.elapsedLabel(at: start.addingTimeInterval(85)) == "1分 25秒")
    #expect(working.elapsedLabel(at: start.addingTimeInterval(86)) == "1分 26秒")
    #expect(working.elapsedLabel(at: start.addingTimeInterval(3663)) == "1时 1分 3秒")
    #expect(working.elapsedLabel(at: start.addingTimeInterval(-1)) == "0秒")
    for status in ["completed", "failed", "interrupted"] {
      native["status"] = status
      native["latestRunCompletedAt"] = "2026-01-01T00:02:25Z"
      let done = try #require(ConversationSubagent.children(parentID: "p", threads: [native]).first)
      #expect(done.elapsedLabel(at: start.addingTimeInterval(1000)) == "1分 25秒")
    }
  }

  @Test func missingOrInvalidTimingDoesNotInventElapsedTime() throws {
    let now = T3DesktopClient.date("2026-01-01T01:00:00Z")
    var native = thread("c", parent: "p", status: "completed", date: "2026-01-01T00:00:00Z")
    native["latestRunStartedAt"] = "2026-01-01T00:01:00Z"
    for end in [NSNull(), "invalid", "2026-01-01T00:00:59Z"] as [Any] {
      native["latestRunCompletedAt"] = end
      let task = try #require(ConversationSubagent.children(parentID: "p", threads: [native]).first)
      #expect(task.elapsedLabel(at: now) == nil)
    }
    native["status"] = "queued"
    native["latestRunCompletedAt"] = "2026-01-01T00:02:00Z"
    let queued = try #require(ConversationSubagent.children(parentID: "p", threads: [native]).first)
    #expect(queued.elapsedLabel(at: now) == nil)
    native["status"] = "running"
    native["latestRunStartedAt"] = "bad-date"
    let invalid = try #require(ConversationSubagent.children(parentID: "p", threads: [native]).first)
    #expect(invalid.elapsedLabel(at: now) == nil)
  }

  @Test func invalidDatesAndUnknownStatesAreNotInventedSuccess() {
    let children = ConversationSubagent.children(parentID: "p", threads: [
      thread("unknown", parent: "p", status: "new-server-state", date: "bad-date"),
      thread("failed", parent: "p", status: "failed", date: "2026-01-01T00:00:00Z"),
    ])
    #expect(children.map(\.id) == ["failed", "unknown"])
    #expect(children[0].status == .failed)
    #expect(children[1].status == .unknown)
    #expect(children[1].createdAt == nil)
    let rows = ConversationTimelineRow.build(messages: [], children: children)
    #expect(rows.count == 1)
    #expect(ConversationTimelineRow.build(messages: [], children: []).isEmpty)
  }
}

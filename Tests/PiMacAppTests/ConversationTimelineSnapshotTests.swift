import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ConversationTimelineSnapshotTests {
  private func messages() -> [ChatEntry] {
    [
      ChatEntry(
        id: "u", kind: .user, title: "", text: "start",
        timestamp: Date(timeIntervalSince1970: 0)),
      ChatEntry(
        id: "tool", kind: .tool, title: "read", text: "old result",
        timestamp: Date(timeIntervalSince1970: 5)),
      ChatEntry(
        id: "tail", kind: .assistant, title: "", text: "finished",
        timestamp: Date(timeIntervalSince1970: 10)),
    ]
  }

  @Test func subagentsFollowTheLoadedHistoryWindowRegardlessOfStatus() {
    let recent = messages().map { entry in
      var entry = entry
      entry.timestamp = entry.timestamp?.addingTimeInterval(100)
      return entry
    }
    for status in [ConversationSubagent.Status.completed, .failed, .working, .queued] {
      let children = [50.0, 100, 105, 120].enumerated().map { index, time in
        ConversationSubagent(
          id: "c\(index)", title: "task", model: "",
          createdAt: Date(timeIntervalSince1970: time), status: status,
          startedAt: nil, completedAt: nil)
      }
      let initial = ConversationTimelineSnapshot(
        messages: recent, children: children, hasMoreHistory: true)
      #expect(
        initial.rowIDs == [
          "turn-u", "subagents-c1", "turn-tool", "subagents-c2",
          "turn-tail", "subagents-c3",
        ])
      // 载入包含委派发生时间的旧页后才显示；分页尚未结束也不应继续隐藏。
      let expanded = ConversationTimelineSnapshot(
        messages: messages() + recent, children: children, hasMoreHistory: true)
      #expect(expanded.rowIDs.contains("subagents-c0"))
      #expect(expanded.rowIDs.filter { $0 == "subagents-c0" }.count == 1)
      // 完整历史可能没有委派之前的正文，不能再按第一条消息截断。
      let complete = ConversationTimelineSnapshot(
        messages: recent, children: children, hasMoreHistory: false)
      #expect(complete.rowIDs.first == "subagents-c0")
    }
  }

  @Test func boundedEmptyHistoryDoesNotInventAWindowForDatedSubagents() {
    let dated = ConversationSubagent(
      id: "dated", title: "task", model: "", createdAt: Date(timeIntervalSince1970: 5),
      status: .completed, startedAt: nil, completedAt: nil)
    let unknown = ConversationSubagent(
      id: "unknown", title: "task", model: "", createdAt: nil,
      status: .unknown, startedAt: nil, completedAt: nil)
    for entries in [[], [ChatEntry(id: "no-date", kind: .assistant, title: "", text: "text")]] {
      let bounded = ConversationTimelineSnapshot(
        messages: entries, children: [dated, unknown], hasMoreHistory: true)
      #expect(!bounded.rowIDs.contains("subagents-dated"))
      #expect(bounded.rowIDs.contains("subagents-unknown"))
      let complete = ConversationTimelineSnapshot(
        messages: entries, children: [dated, unknown], hasMoreHistory: false)
      #expect(complete.rowIDs.contains("subagents-dated"))
    }
  }

  @Test func pagingStateParticipatesInTheAppTimelineCache() {
    let app = AppModel(restoreLastProjectOnLaunch: false)
    app.currentSessionPath = "t3:one"
    app.apply(["hasMoreHistory": true, "thread": ["id": "one", "messages": []]])
    let child = ConversationSubagent(
      id: "c", title: "task", model: "", createdAt: Date(timeIntervalSince1970: 5),
      status: .completed, startedAt: nil, completedAt: nil)
    app.messages = [
      ChatEntry(
        id: "recent", kind: .user, title: "", text: "recent",
        timestamp: Date(timeIntervalSince1970: 100))
    ]
    let bounded = app.conversationTimeline(children: [child])
    #expect(bounded.rowIDs == ["turn-recent"])
    #expect(app.conversationTimeline(children: [child]) === bounded)
    app.apply(["hasMoreHistory": false, "thread": ["id": "one", "messages": []]])
    let complete = app.conversationTimeline(children: [child])
    #expect(complete !== bounded)
    #expect(complete.rowIDs == ["subagents-c"])
  }

  @Test func composerOnlyChangesReuseTheImmutableSnapshot() throws {
    let app = AppModel()
    app.messages = messages()
    let initial = app.conversationTimeline(children: [])
    for index in 0..<100 {
      app.composerText = "draft \(index)"
      #expect(app.conversationTimeline(children: []) === initial)
    }
    #expect(app.composerText == "draft 99")
    #expect(initial.rowIDs == ["turn-u"])
    #expect(initial.lastTurnID == "u")
    let turn = try #require(initial.rows.first)
    guard case .turn(let value) = turn else {
      Issue.record("Missing turn")
      return
    }
    #expect(value.entries == app.messages)
  }

  @Test func earlierTextEditWithUnchangedCountAndTailIsVisible() throws {
    let app = AppModel()
    app.messages = messages()
    let initial = app.conversationTimeline(children: [])
    app.messages[0].text = "revised prompt"
    let updated = app.conversationTimeline(children: [])
    guard case .turn(let turn) = try #require(updated.rows.first),
      case .turn(let oldTurn) = try #require(initial.rows.first)
    else {
      Issue.record("Missing turn")
      return
    }
    #expect(turn.user?.text == "revised prompt")
    #expect(turn.finalAssistant?.text == "finished")
    #expect(oldTurn.user?.text == "start")
    #expect(updated.rowIDs == initial.rowIDs)
  }

  @Test func earlierToolPayloadAndNestedOutputAreRefreshed() throws {
    let app = AppModel()
    app.messages = messages()
    _ = app.conversationTimeline(children: [])
    app.messages[1].toolInput = "new input"
    app.messages[1].text = "new result"
    app.messages[1].isError = true
    app.messages[1].childToolEntries = [
      ChatEntry(id: "nested", kind: .tool, title: "read", text: "nested result")
    ]
    let snapshot = app.conversationTimeline(children: [])
    guard case .turn(let turn) = try #require(snapshot.rows.first) else {
      Issue.record("Missing turn")
      return
    }
    let tool = try #require(turn.activity.first)
    #expect(tool.text == "new result")
    #expect(tool.toolInput == "new input")
    #expect(tool.isError)
    #expect(tool.childToolEntries.map(\.text) == ["nested result"])
    #expect(turn.finalAssistant?.text == "finished")
  }

  @Test func equalCountHistoryReplacementDoesNotReuseOldRows() throws {
    let app = AppModel()
    app.messages = messages()
    let initial = app.conversationTimeline(children: [])
    app.messages = [
      ChatEntry(id: "replacement", kind: .user, title: "", text: "different history"),
      ChatEntry(id: "notice", kind: .system, title: "", text: "notice"),
      app.messages[2],
    ]
    let updated = app.conversationTimeline(children: [])
    #expect(updated.rowIDs == ["turn-replacement", "turn-notice", "turn-tail"])
    #expect(updated.lastTurnID == "tail")
    #expect(initial.rowIDs == ["turn-u"])
    guard case .turn(let turn) = try #require(updated.rows.first) else {
      Issue.record("Missing turn")
      return
    }
    #expect(turn.user?.text == "different history")
  }

  @Test func everyChildPayloadFieldParticipatesInInvalidation() throws {
    let app = AppModel()
    app.messages = messages()
    let base = ConversationSubagent(
      id: "c", title: "task", model: "model", createdAt: nil, status: .working,
      startedAt: Date(timeIntervalSince1970: 1), completedAt: nil)
    let variants = [
      ConversationSubagent(
        id: "other", title: base.title, model: base.model,
        createdAt: nil, status: base.status, startedAt: base.startedAt, completedAt: nil),
      ConversationSubagent(
        id: base.id, title: "renamed", model: base.model,
        createdAt: nil, status: base.status, startedAt: base.startedAt, completedAt: nil),
      ConversationSubagent(
        id: base.id, title: base.title, model: "other-model",
        createdAt: nil, status: base.status, startedAt: base.startedAt, completedAt: nil),
      ConversationSubagent(
        id: base.id, title: base.title, model: base.model,
        createdAt: Date(timeIntervalSince1970: 20), status: base.status,
        startedAt: base.startedAt, completedAt: nil),
      ConversationSubagent(
        id: base.id, title: base.title, model: base.model,
        createdAt: nil, status: .completed, startedAt: base.startedAt, completedAt: nil),
      ConversationSubagent(
        id: base.id, title: base.title, model: base.model,
        createdAt: nil, status: base.status, startedAt: Date(timeIntervalSince1970: 2),
        completedAt: nil),
      ConversationSubagent(
        id: base.id, title: base.title, model: base.model,
        createdAt: nil, status: base.status, startedAt: base.startedAt,
        completedAt: Date(timeIntervalSince1970: 9)),
    ]
    for child in variants {
      let initial = app.conversationTimeline(children: [base])
      let updated = app.conversationTimeline(children: [child])
      guard case .subagents(let tasks) = try #require(updated.rows.last) else {
        Issue.record("Missing child card")
        return
      }
      #expect(tasks == [child])
      #expect(updated !== initial)
      #expect(updated.rowIDs == ["turn-u", "subagents-\(child.id)"])
      #expect(updated.lastTurnID == "u")
      #expect(app.conversationTimeline(children: [child]) === updated)
    }
  }

  @Test func childTimeMovesBoundaryAndRemovalRestoresWholeTurn() throws {
    let app = AppModel()
    app.messages = messages()
    let early = ConversationSubagent(
      id: "c", title: "task", model: "", createdAt: Date(timeIntervalSince1970: 3),
      status: .working, startedAt: nil, completedAt: nil)
    let late = ConversationSubagent(
      id: early.id, title: early.title, model: early.model,
      createdAt: Date(timeIntervalSince1970: 7), status: early.status,
      startedAt: nil, completedAt: nil)
    #expect(
      app.conversationTimeline(children: [early]).rowIDs == [
        "turn-u", "subagents-c", "turn-tool",
      ])
    let moved = app.conversationTimeline(children: [late])
    #expect(moved.rowIDs == ["turn-u", "subagents-c", "turn-tail"])
    #expect(moved.lastTurnID == "tail")
    let removed = app.conversationTimeline(children: [])
    #expect(removed.rowIDs == ["turn-u"])
    #expect(removed.lastTurnID == "u")
    guard case .turn(let turn) = try #require(removed.rows.first) else {
      Issue.record("Missing turn")
      return
    }
    #expect(turn.entries == app.messages)
  }

  @Test func childOrderIsPreservedAndNotTreatedAsASet() throws {
    let app = AppModel()
    let first = ConversationSubagent(
      id: "a", title: "first", model: "", createdAt: nil,
      status: .queued, startedAt: nil, completedAt: nil)
    let second = ConversationSubagent(
      id: "b", title: "second", model: "", createdAt: nil,
      status: .working, startedAt: nil, completedAt: nil)
    #expect(app.conversationTimeline(children: [first, second]).rowIDs == ["subagents-a"])
    let reversed = app.conversationTimeline(children: [second, first])
    #expect(reversed.rowIDs == ["subagents-b"])
    #expect(reversed.lastTurnID == nil)
    guard case .subagents(let tasks) = try #require(reversed.rows.first) else {
      Issue.record("Missing child cards")
      return
    }
    #expect(tasks == [second, first])
  }

  @Test func separateModelsDoNotShareSnapshotsOrInvalidation() throws {
    let first = AppModel()
    let second = AppModel()
    first.messages = messages()
    second.messages = messages()
    let firstSnapshot = first.conversationTimeline(children: [])
    let secondSnapshot = second.conversationTimeline(children: [])
    #expect(firstSnapshot !== secondSnapshot)
    first.messages[0].text = "first model only"
    #expect(second.conversationTimeline(children: []) === secondSnapshot)
    guard case .turn(let turn) = try #require(secondSnapshot.rows.first) else {
      Issue.record("Missing turn")
      return
    }
    #expect(turn.user?.text == "start")
  }

  @Test func emptyResetClearsRowsIDsAndLastTurn() {
    let app = AppModel()
    app.messages = messages()
    let populated = app.conversationTimeline(children: [])
    app.messages.removeAll()
    let empty = app.conversationTimeline(children: [])
    #expect(empty.rows.isEmpty)
    #expect(empty.rowIDs.isEmpty)
    #expect(empty.lastTurnID == nil)
    #expect(app.conversationTimeline(children: []) === empty)
    #expect(populated.rowIDs == ["turn-u"])
    app.messages = messages()
    #expect(app.conversationTimeline(children: []).rowIDs == ["turn-u"])
  }

  @Test func assigningEqualMessagesStillInvalidatesTheSnapshot() {
    let app = AppModel()
    let history = messages()
    app.messages = history
    let initial = app.conversationTimeline(children: [])
    app.messages = history
    let reassigned = app.conversationTimeline(children: [])
    #expect(reassigned !== initial)
    #expect(reassigned.rowIDs == initial.rowIDs)
    #expect(reassigned.lastTurnID == initial.lastTurnID)
  }
}

import Foundation
import Testing

@testable import PiMacApp

struct TaskStatusNotificationTests {
  private func thread(_ id: String = "thread", turn: String = "turn", state: String) -> [String:
    Any]
  {
    ["id": id, "title": "Test", "latestTurn": ["turnId": turn, "state": state]]
  }

  @Test func initialHistoryAndIdenticalPollsDoNotNotify() {
    var tracker = TaskStatusTracker()
    #expect(tracker.consume([thread(state: "completed")]).isEmpty)
    #expect(tracker.consume([thread(state: "completed")]).isEmpty)
    #expect(tracker.consume([]).isEmpty)
    #expect(tracker.consume([thread(state: "completed")]).isEmpty)
  }

  @Test func observesAllThreadsAndTerminalStatesOnce() {
    var tracker = TaskStatusTracker()
    #expect(tracker.consume([thread(state: "running")]).isEmpty)
    let events = tracker.consume([thread(state: "completed"), thread("other", state: "error")])
    #expect(events.map(\.state) == ["completed", "error"])
    #expect(events.first?.title == "Test")
    #expect(tracker.consume([thread(state: "completed"), thread("other", state: "error")]).isEmpty)
    #expect(
      tracker.consume([thread(turn: "next", state: "interrupted")]).first?.message == "任务已取消。")
  }

  @Test func fastTurnBetweenPollsStillNotifies() {
    var tracker = TaskStatusTracker()
    _ = tracker.consume([thread(state: "completed")])
    #expect(tracker.consume([thread(turn: "fast", state: "completed")]).count == 1)
    #expect(tracker.consume([thread(turn: "fast", state: "completed")]).isEmpty)
  }
}

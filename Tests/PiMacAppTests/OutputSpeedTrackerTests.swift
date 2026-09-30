import Testing

@testable import PiMacApp

struct OutputSpeedTrackerTests {
  private func start() -> [String: Any] {
    ["type": "message_start", "message": ["role": "assistant"]]
  }
  private func end(_ tokens: Int) -> [String: Any] {
    ["type": "message_end", "message": ["role": "assistant", "usage": ["output": tokens]]]
  }

  @Test func streamingUsageIsCumulativeAndFinalUsageIsAuthoritative() {
    var tracker = OutputSpeedTracker()
    tracker.consume(start(), now: 10)
    tracker.consume(
      [
        "type": "message_update", "usage": ["output": 20],
        "assistantMessageEvent": ["type": "text_delta", "delta": "hello"],
      ], now: 12)
    #expect(tracker.tokensPerSecond == 10)
    tracker.consume(
      [
        "type": "message_update", "usage": ["output": 30],
        "assistantMessageEvent": ["type": "thinking_delta", "delta": "thinking"],
      ], now: 13)
    #expect(tracker.tokensPerSecond == 10)
    tracker.consume(end(80), now: 14)
    #expect(tracker.tokensPerSecond == 20)
  }

  @Test func excludesToolWaitAndKeepsFinalSpeedUntilReset() {
    var tracker = OutputSpeedTracker()
    tracker.consume(start(), now: 0)
    tracker.consume(end(100), now: 2)
    tracker.consume(["type": "tool_execution_end"], now: 50)
    #expect(tracker.tokensPerSecond == 50)
    tracker.consume(start(), now: 100)
    tracker.consume(end(200), now: 104)
    #expect(tracker.tokensPerSecond == 50)
    tracker.consume(["type": "agent_settled"], now: 200)
    #expect(tracker.tokensPerSecond == 50)
    tracker.reset()
    #expect(tracker.tokensPerSecond == nil)
  }

  @Test func ignoresNonAssistantMessagesMissingUsageAndZeroDuration() {
    var tracker = OutputSpeedTracker()
    tracker.consume(["type": "message_start", "message": ["role": "user"]], now: 0)
    tracker.consume(end(100), now: 2)
    #expect(tracker.tokensPerSecond == nil)
    tracker.consume(start(), now: 5)
    tracker.consume(end(100), now: 5)
    #expect(tracker.tokensPerSecond == nil)
    tracker.consume(start(), now: 10)
    tracker.consume(end(0), now: 20)
    #expect(tracker.tokensPerSecond == nil)
    tracker.consume(start(), now: 30)
    tracker.consume(end(100), now: 32)
    #expect(tracker.tokensPerSecond == 50)
  }
}

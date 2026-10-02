import Foundation
import Testing

@testable import PiMacApp

struct StreamActivityTests {
  private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
  private func update(_ type: String, delta: String = "") -> [String: Any] {
    ["type": "message_update", "assistantMessageEvent": ["type": type, "delta": delta]]
  }

  @Test func encryptedReasoningWithoutVisibleTextIsActivity() {
    var activity = StreamActivity()
    activity.consume(["type": "agent_start"], now: date(0))
    #expect(activity.label(at: date(10)) == "等待模型响应 · 10秒（尚未收到流式数据）")
    activity.consume(update("thinking_start"), now: date(10))
    #expect(activity.phase == .thinking)
    activity.consume(update("thinking_end"), now: date(20))
    #expect(activity.lastResponseAt == date(20))
    #expect(activity.label(at: date(55)) == "正在推理 · 55秒 · 35秒前收到响应（等待新数据）")
    activity.consume(update("thinking_start"), now: date(56))
    #expect(activity.label(at: date(56)) == "正在推理 · 56秒 · 0秒前收到响应")
  }

  @Test func toolGenerationIsNotToolExecution() {
    var activity = StreamActivity()
    activity.consume(update("toolcall_delta", delta: "partial arguments"), now: date(10))
    #expect(activity.phase == .preparingTool)
    activity.consume(["type": "tool_execution_start"], now: date(11))
    #expect(activity.label(at: date(90)) == "正在执行工具…")
    activity.consume(["type": "tool_execution_end"], now: date(100))
    #expect(activity.phase == .waiting)
    #expect(activity.lastResponseAt == nil)
    activity.consume(update("text_delta", delta: "hello"), now: date(101))
    #expect(activity.phase == .responding)
  }

  @Test func retriesAndNextRequestsResetOldHeartbeat() {
    var activity = StreamActivity()
    activity.consume(update("thinking_start"), now: date(10))
    activity.consume(["type": "auto_retry_start"], now: date(11))
    #expect(activity.label(at: date(100)) == "正在自动重试…")
    activity.consume(["type": "auto_retry_end"], now: date(101))
    #expect(activity.lastResponseAt == nil)
    activity.consume(update("thinking_start"), now: date(102))
    activity.consume(["type": "message_start", "message": ["role": "assistant"]], now: date(110))
    #expect(activity.phase == .waiting)
    #expect(activity.startedAt == date(110))
    #expect(activity.lastResponseAt == nil)
    // agent_end may precede auto_retry_start; only settled means the logical task is done.
    activity.consume(["type": "agent_end", "willRetry": true], now: date(111))
    #expect(activity.phase == .waiting)
    activity.consume(["type": "agent_settled"], now: date(112))
    #expect(activity.label(at: date(113)) == nil)
  }

  @Test func unrelatedEventsDoNotInventAHeartbeatAndUpdatesAreCoalesced() {
    var activity = StreamActivity()
    activity.consume(["type": "message_start", "message": ["role": "user"]], now: date(0))
    activity.consume(update("unknown"), now: date(1))
    #expect(activity.phase == nil)
    activity.consume(update("thinking_delta"), now: date(2.1))
    let previous = activity
    activity.consume(update("thinking_delta"), now: date(2.9))
    #expect(activity == previous)
    activity.consume(["type": "extension_ui_request"], now: date(50))
    #expect(activity.lastResponseAt == date(2))
  }
}

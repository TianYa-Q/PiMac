import XCTest

@testable import PiMacApp

final class TelegramCompletionPresentationTests: XCTestCase {
  func testTerminalStopReasonsOverridePartialReply() {
    XCTAssertEqual(
      TelegramPresentation.taskOutcome(stopReason: "aborted", hasReply: true), .stopped)
    XCTAssertEqual(TelegramPresentation.taskOutcome(stopReason: "error", hasReply: true), .failed)
    XCTAssertEqual(TelegramPresentation.taskOutcome(stopReason: "stop", hasReply: true), .completed)
    XCTAssertEqual(
      TelegramPresentation.taskOutcome(stopReason: nil, hasReply: false), .endedWithoutReply)
    XCTAssertEqual(
      TelegramPresentation.taskOutcome(stopReason: "stop", hasReply: false), .endedWithoutReply)
    XCTAssertEqual(TelegramPresentation.taskOutcome(stopReason: "error", hasReply: false), .failed)
  }

  func testSuccessfulRepliesStayUnmodified() {
    let reply = "# 报告\n\n[下载](report.pdf)\n```swift\nlet x = 1\n```"
    XCTAssertEqual(
      TelegramPresentation.resultText(outcome: .completed, reply: reply, error: nil), reply)
  }

  func testStoppedAndFailedRepliesClearlyLabelPartialOutput() {
    let stopped = TelegramPresentation.resultText(outcome: .stopped, reply: "partial", error: nil)
    XCTAssertTrue(stopped.hasPrefix("⏹ 任务已停止"))
    XCTAssertTrue(stopped.contains("部分回复：\n\npartial"))
    let failed = TelegramPresentation.resultText(
      outcome: .failed, reply: "partial", error: "rate limit")
    XCTAssertTrue(failed.hasPrefix("❌ 任务执行失败"))
    XCTAssertTrue(failed.contains("rate limit"))
    XCTAssertTrue(failed.contains("部分回复：\n\npartial"))
    XCTAssertFalse(failed.contains("任务完成"))
  }

  func testEmptyRepliesDoNotClaimSuccessfulCompletion() {
    let empty = TelegramPresentation.resultText(outcome: .endedWithoutReply, reply: nil, error: nil)
    XCTAssertTrue(empty.contains("无文本回复"))
    XCTAssertTrue(empty.contains("详情见 Mac 执行记录"))
    let stopped = TelegramPresentation.resultText(outcome: .stopped, reply: nil, error: nil)
    XCTAssertFalse(stopped.contains("部分回复"))
    let failed = TelegramPresentation.resultText(outcome: .failed, reply: nil, error: nil)
    XCTAssertTrue(failed.contains("请在 Mac 查看错误"))
  }

  func testCompletionSummarySeparatesExecutionAndDelivery() {
    let completed = TelegramPresentation.completionSummary(
      outcome: .completed, delivered: true, elapsed: "1 分 3 秒", queuedCount: 2)
    XCTAssertTrue(completed.hasPrefix("✅ 任务完成"))
    XCTAssertTrue(completed.contains("耗时  1 分 3 秒"))
    XCTAssertTrue(completed.contains("回复可继续原会话"))
    XCTAssertTrue(completed.contains("排队  2 条 · 自动继续"))
    let failedDelivery = TelegramPresentation.completionSummary(
      outcome: .stopped, delivered: false, elapsed: "0 分 5 秒", queuedCount: 0)
    XCTAssertTrue(failedDelivery.hasPrefix("⏹ 任务已停止"))
    XCTAssertTrue(failedDelivery.contains("自动重试，无需重发"))
    XCTAssertFalse(failedDelivery.contains("等待任务"))
    XCTAssertFalse(failedDelivery.contains("任务执行失败"))
  }

  func testFailureDetailsAreBoundedForMobileCards() {
    let detail = String(repeating: "错误详情", count: 100)
    let failed = TelegramPresentation.resultText(outcome: .failed, reply: nil, error: detail)
    XCTAssertFalse(failed.contains(detail))
    XCTAssertTrue(failed.contains("…"))
    XCTAssertLessThan(failed.count, 280)
  }
}

import XCTest

@testable import PiMacApp

final class TelegramCompactCopyTests: XCTestCase {
  func testReceiptsFitSmallCardsAndRetainRoutingAndBlockers() {
    let receipt = TelegramPresentation.taskNotice(
      project: "demo", originalSession: true, position: 2, preview: "修复登录问题",
      attachmentCount: 1, waitingForConfirmation: true)
    XCTAssertEqual(
      receipt,
      """
      📥 任务已排队
      项目  demo
      目标  原会话 · 不改默认选择
      排队  第 2 位
      摘要  修复登录问题
      附件  1 个

      待 Mac 确认，随后自动执行。
      可编辑原消息；取消仅限此条。
      """)
    XCTAssertLessThan(receipt.count, 150)
    let connecting = TelegramPresentation.taskNotice(
      project: "demo", originalSession: false, position: 1, waitingForConnection: true)
    XCTAssertTrue(connecting.contains("连接重试中，无需重发"))
    XCTAssertFalse(connecting.contains("待 Mac 确认"))
  }

  @MainActor
  func testStatusUsesCompactFieldsAndKeepsSessionIdentity() {
    let status = TelegramControl.statusMessage(
      project: "demo", session: "修复登录", sessionPath: "/tmp/session-abcdef123456.jsonl",
      connection: .connected, busy: true, loading: false, detail: "正在执行",
      model: "openai/codex", thinking: "high", contextPercent: 42, account: "work",
      queuedCount: 2, elapsed: "1 分 3 秒")
    XCTAssertEqual(
      status,
      """
      ⚡ 执行中
      项目  demo
      会话  修复登录 · #abcdef123456
      耗时  1 分 3 秒
      排队  2 条

      模型  openai/codex
      推理  high
      账户  work
      上下文  42%

      ↩ 回复此卡 → 此会话，不改默认选择
      """)
    XCTAssertLessThan(status.count, 180)
  }

  @MainActor
  func testDynamicLabelsStaySingleLineAndErrorsRemainVisible() {
    let long = String(repeating: "很长的内容\n", count: 100)
    let status = TelegramControl.statusMessage(
      project: long, session: "demo", connection: .failed(long), busy: false,
      loading: false, detail: long, model: long, account: long)
    XCTAssertFalse(status.contains(long))
    XCTAssertTrue(status.hasPrefix("连接失败 · "))
    XCTAssertTrue(status.contains("…"))
    XCTAssertLessThanOrEqual(status.components(separatedBy: "\n").count, 12)
    XCTAssertLessThan(status.count, 420)
  }

  func testCompletionDistinguishesSendingRetryAndDeliveryWithoutExtraParagraphs() {
    for delivered: Bool? in [nil, false, true] {
      let summary = TelegramPresentation.completionSummary(
        outcome: .completed, delivered: delivered, elapsed: "1 分 3 秒", queuedCount: 2)
      XCTAssertEqual(summary.components(separatedBy: "\n").count, 4)
      XCTAssertLessThan(summary.count, 90)
      switch delivered {
      case nil: XCTAssertTrue(summary.contains("结果发送中"))
      case false?: XCTAssertTrue(summary.contains("结果未送达 · 自动重试"))
      case true?: XCTAssertTrue(summary.contains("结果已发送"))
      }
    }
  }
}

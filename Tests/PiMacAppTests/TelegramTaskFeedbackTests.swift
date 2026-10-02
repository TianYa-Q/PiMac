import XCTest

@testable import PiMacApp

final class TelegramTaskFeedbackTests: XCTestCase {
  func testOnlyMatchingCurrentCardsMayMutateSessions() {
    let first = TelegramMessageSessionStore.Location(
      project: "/first", sessionPath: "/first/a.jsonl")
    let otherSession = TelegramMessageSessionStore.Location(
      project: "/first", sessionPath: "/first/b.jsonl")
    let otherProject = TelegramMessageSessionStore.Location(
      project: "/second", sessionPath: "/second/a.jsonl")
    for command in [
      "/stop", "/new", "/compact", "model:1", "thinking:high", "account:2", "session:abc",
    ] {
      XCTAssertTrue(TelegramPresentation.canPerform(command, card: first, selected: first), command)
      XCTAssertFalse(
        TelegramPresentation.canPerform(command, card: first, selected: otherSession), command)
      XCTAssertFalse(
        TelegramPresentation.canPerform(command, card: first, selected: otherProject), command)
      XCTAssertFalse(TelegramPresentation.canPerform(command, card: nil, selected: first), command)
      XCTAssertFalse(TelegramPresentation.canPerform(command, card: first, selected: nil), command)
    }
  }

  func testExpiredCardsStillAllowNavigationAndPerTaskCancellation() {
    for command in [
      "/status", "/projects", "/sessions", "/model", "/thinking", "/usage 2", "/help", "select:2",
      "cancel:\(UUID().uuidString)",
    ] {
      XCTAssertTrue(TelegramPresentation.canPerform(command, card: nil, selected: nil), command)
    }
  }

  func testNewDraftDoesNotAuthorizeCardsFromSavedSession() {
    let saved = TelegramMessageSessionStore.Location(
      project: "/first", sessionPath: "/first/a.jsonl")
    let draft = TelegramMessageSessionStore.Location(project: "/first", sessionPath: "")
    XCTAssertFalse(TelegramPresentation.canPerform("/stop", card: draft, selected: saved))
    XCTAssertFalse(TelegramPresentation.canPerform("/compact", card: saved, selected: draft))
    XCTAssertTrue(TelegramPresentation.canPerform("/new", card: draft, selected: draft))
  }

  func testReceiptsShowRoutingPreviewAndAttachmentsWithoutLongPrompts() {
    let preview = " 修复\n  问题 " + String(repeating: "长", count: 150)
    let receipt = TelegramPresentation.taskNotice(
      project: "demo", originalSession: true, preview: preview, attachmentCount: 2)
    XCTAssertTrue(receipt.hasPrefix("✅ 任务已提交"))
    XCTAssertTrue(receipt.contains("目标  原会话"))
    XCTAssertTrue(receipt.contains("不改默认选择"))
    XCTAssertTrue(receipt.contains("附件  2 个"))
    XCTAssertTrue(receipt.contains("摘要  修复 问题"))
    XCTAssertFalse(receipt.contains(preview))
    XCTAssertFalse(receipt.contains("等待队列"))
    XCTAssertFalse(receipt.contains("取消按钮"))
    let previewLine = receipt.split(separator: "\n").first(where: { $0.hasPrefix("摘要") })!
    XCTAssertLessThanOrEqual(previewLine.count, 52)
  }

  func testQueuedReceiptExplainsActualBlockerAndEditBehavior() {
    let queued = TelegramPresentation.taskNotice(
      project: "demo", originalSession: false, position: 3,
      waitingForConnection: true, waitingForConfirmation: true)
    XCTAssertTrue(queued.hasPrefix("📥 任务已排队"))
    XCTAssertTrue(queued.contains("排队  第 3 位"))
    XCTAssertTrue(queued.contains("待 Mac 确认"))
    XCTAssertFalse(queued.contains("自动重试连接"))
    XCTAssertTrue(queued.contains("可编辑原消息"))
    XCTAssertTrue(queued.contains("取消仅限此条"))
    let connecting = TelegramPresentation.taskNotice(
      project: "demo", originalSession: false, position: 1, waitingForConnection: true)
    XCTAssertTrue(connecting.contains("连接重试中，无需重发"))
    XCTAssertFalse(connecting.contains("Mac 上处理"))
  }
}

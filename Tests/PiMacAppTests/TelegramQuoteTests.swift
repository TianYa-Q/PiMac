import Foundation
import XCTest

@testable import PiMacApp

final class TelegramQuoteTests: XCTestCase {
  func testPartialQuoteIsDecodedAndIncludedWithoutChangingReplyRouting() throws {
    let json =
      #"{"update_id":5,"message":{"message_id":102,"reply_to_message":{"message_id":99,"text":"完整原消息"},"quote":{"text":"选中的一段\n第二行","position":2,"is_manual":true},"date":200,"from":{"id":42,"is_bot":false},"chat":{"id":42,"type":"private"},"text":"解释一下"}}"#
    let update = try JSONDecoder().decode(TelegramUpdate.self, from: Data(json.utf8))
    let message = try XCTUnwrap(update.authorizedMessage(userID: 42, since: .distantPast))
    XCTAssertEqual(message.replyToMessage?.messageID, 99)
    XCTAssertEqual(message.quote?.text, "选中的一段\n第二行")
    let prompt = TelegramUpdate.promptText(message.text ?? "", quote: message.quote?.text)
    XCTAssertTrue(prompt.contains("> 选中的一段\n> 第二行"))
    XCTAssertTrue(prompt.hasSuffix("用户回复：\n解释一下"))
    XCTAssertFalse(prompt.contains("完整原消息"))
  }

  func testOrdinaryReplyAndEmptyQuoteLeavePromptUnchanged() {
    XCTAssertEqual(TelegramUpdate.promptText("继续", quote: nil), "继续")
    XCTAssertEqual(TelegramUpdate.promptText("继续", quote: ""), "继续")
  }

  func testAttachmentWithoutCaptionStillIncludesQuote() {
    XCTAssertTrue(TelegramUpdate.promptText("", quote: "这段话").contains("> 这段话"))
  }
}

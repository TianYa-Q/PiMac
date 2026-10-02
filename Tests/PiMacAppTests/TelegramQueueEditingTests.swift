import XCTest

@testable import PiMacApp

final class TelegramQueueEditingTests: XCTestCase {
  func testEditingKeepsFIFOPositionAndDoesNotRequeueMissingTasks() {
    var queue = TelegramPromptQueue<String>()
    queue.append("first")
    queue.append("second")
    queue.append("third")
    XCTAssertEqual(queue.updateFirst(where: { $0 == "second" }) { $0 = "edited" }, 2)
    XCTAssertEqual(queue.items, ["first", "edited", "third"])
    XCTAssertNil(queue.updateFirst(where: { $0 == "missing" }) { $0 = "new" })
    XCTAssertEqual(queue.items, ["first", "edited", "third"])
  }

  func testCancellingOnlyRemovesMatchingTaskAndIsIdempotent() {
    var queue = TelegramPromptQueue<String>()
    queue.append("first")
    queue.append("second")
    queue.append("third")
    XCTAssertEqual(queue.removeFirst(where: { $0 == "second" }), "second")
    XCTAssertNil(queue.removeFirst(where: { $0 == "second" }))
    XCTAssertEqual(queue.removeFirst(), "first")
    XCTAssertEqual(queue.removeFirst(), "third")
    XCTAssertTrue(queue.isEmpty)
  }

  func testStartedTasksCannotBeEditedOrCancelled() {
    var queue = TelegramPromptQueue<String>()
    queue.append("started")
    queue.append("waiting")
    XCTAssertEqual(queue.removeFirst(), "started")
    XCTAssertNil(queue.updateFirst(where: { $0 == "started" }) { $0 = "edited" })
    XCTAssertNil(queue.removeFirst(where: { $0 == "started" }))
    XCTAssertEqual(queue.items, ["waiting"])
  }

  func testEditedMessageDecodingAuthorizationAndQuote() throws {
    let json =
      #"{"update_id":6,"edited_message":{"message_id":102,"quote":{"text":"quoted"},"date":1,"from":{"id":42,"is_bot":false},"chat":{"id":42,"type":"private"},"text":"edited"}}"#
    let update = try JSONDecoder().decode(TelegramUpdate.self, from: Data(json.utf8))
    let message = try XCTUnwrap(update.authorizedEdit(userID: 42))
    XCTAssertEqual(message.messageID, 102)
    XCTAssertEqual(message.text, "edited")
    XCTAssertTrue(
      TelegramUpdate.promptText(message.text!, quote: message.quote?.text).contains("> quoted"))
    XCTAssertNil(update.authorizedEdit(userID: 99))
    XCTAssertNil(update.authorizedMessage(userID: 42, since: .distantPast))
    for (old, new) in [("private", "group"), ("\"is_bot\":false", "\"is_bot\":true")] {
      let bad = try JSONDecoder().decode(
        TelegramUpdate.self, from: Data(json.replacingOccurrences(of: old, with: new).utf8))
      XCTAssertNil(bad.authorizedEdit(userID: 42))
    }
    XCTAssertTrue(TelegramControl.allowedUpdates.contains("edited_message"))
  }

  func testCancellationCallbacksRequireValidIDAndAuthorizedSender() throws {
    let json =
      #"{"update_id":6,"callback_query":{"id":"cb","from":{"id":42,"is_bot":false},"message":{"message_id":102,"chat":{"id":42,"type":"private"}},"data":"cancel:12345678-1234-1234-1234-123456789abc"}}"#
    let update = try JSONDecoder().decode(TelegramUpdate.self, from: Data(json.utf8))
    XCTAssertNotNil(update.authorizedCallback(userID: 42))
    XCTAssertNil(update.authorizedCallback(userID: 99))
    let bad = try JSONDecoder().decode(
      TelegramUpdate.self,
      from: Data(
        json.replacingOccurrences(of: "12345678-1234-1234-1234-123456789abc", with: "invalid").utf8)
    )
    XCTAssertNil(bad.authorizedCallback(userID: 42))
  }
}

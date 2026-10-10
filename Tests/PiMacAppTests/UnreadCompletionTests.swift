import XCTest
@testable import PiMacApp

@MainActor
final class UnreadCompletionTests: XCTestCase {
  func testCompletionRemainsUnreadUntilSharedReceiptCoversIt() {
    var thread: [String: Any] = [
      "status": "completed",
      "latestRunCompletedAt": "2026-10-10T10:00:00.000Z",
      "lastVisitedAt": NSNull(),
    ]
    XCTAssertTrue(T3V2Presentation.hasUnreadCompletion(thread))
    thread["lastVisitedAt"] = "2026-10-10T09:59:59.000Z"
    XCTAssertTrue(T3V2Presentation.hasUnreadCompletion(thread))
    thread["lastVisitedAt"] = "2026-10-10T10:00:00.000Z"
    XCTAssertFalse(T3V2Presentation.hasUnreadCompletion(thread))
    thread["lastVisitedAt"] = "2026-10-10T11:00:00.000Z"
    XCTAssertFalse(T3V2Presentation.hasUnreadCompletion(thread))
    thread["latestRunCompletedAt"] = "2026-10-10T12:00:00.000Z"
    XCTAssertTrue(T3V2Presentation.hasUnreadCompletion(thread))
  }

  func testOnlySuccessfullyCompletedTasksShowDone() {
    for status in ["running", "waiting", "failed", "cancelled", "interrupted", "idle"] {
      XCTAssertFalse(T3V2Presentation.hasUnreadCompletion([
        "status": status, "latestRunCompletedAt": "2026-10-10T10:00:00.000Z",
      ]))
    }
    XCTAssertFalse(T3V2Presentation.hasUnreadCompletion(["status": "completed"]))
    XCTAssertFalse(T3V2Presentation.hasUnreadCompletion([
      "status": "completed", "latestRunCompletedAt": "invalid",
    ]))
  }
}

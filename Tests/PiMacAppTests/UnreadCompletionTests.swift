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

  func testViewedCompletionCapturesExactReceiptAndLeavesBackgroundUnread() {
    var thread: [String: Any] = [
      "id": "viewed", "status": "running", "lastVisitedAt": NSNull(),
      "latestRunCompletedAt": "2026-10-10T10:00:00.000Z",
    ]
    XCTAssertNil(WorkspaceModel.completionVisit(thread: thread, selectedThreadID: "viewed"))
    thread["status"] = "completed"
    XCTAssertNil(WorkspaceModel.completionVisit(thread: thread, selectedThreadID: "other"))
    XCTAssertNil(WorkspaceModel.completionVisit(thread: thread, selectedThreadID: nil))
    let command = WorkspaceModel.completionVisit(thread: thread, selectedThreadID: "viewed")
    XCTAssertEqual(command?["type"] as? String, "thread.visit")
    XCTAssertEqual(command?["threadId"] as? String, "viewed")
    XCTAssertEqual(command?["visitedAt"] as? String, "2026-10-10T10:00:00.000Z")
    thread["lastVisitedAt"] = command?["visitedAt"]
    XCTAssertNil(WorkspaceModel.completionVisit(thread: thread, selectedThreadID: "viewed"))
    thread["latestRunCompletedAt"] = "2026-10-10T12:00:00.000Z"
    XCTAssertTrue(T3V2Presentation.hasUnreadCompletion(thread))
    XCTAssertEqual(command?["visitedAt"] as? String, "2026-10-10T10:00:00.000Z")
    XCTAssertEqual(
      WorkspaceModel.completionVisit(thread: thread, selectedThreadID: "viewed")?["visitedAt"] as? String,
      "2026-10-10T12:00:00.000Z")
    thread["latestRunCompletedAt"] = "invalid"
    XCTAssertNil(WorkspaceModel.completionVisit(thread: thread, selectedThreadID: "viewed"))
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

import XCTest

@testable import PiMacApp

final class TelegramPresentationTests: XCTestCase {
  func testPaginationClampsAndHandlesEmptyLists() {
    XCTAssertEqual(
      TelegramPresentation.page(-1, count: 0, size: 8),
      .init(number: 1, count: 1, start: 0, end: 0))
    XCTAssertEqual(
      TelegramPresentation.page(Int.max, count: 17, size: 8),
      .init(number: 3, count: 3, start: 16, end: 17))
    XCTAssertEqual(
      TelegramPresentation.page(2, count: 16, size: 8),
      .init(number: 2, count: 2, start: 8, end: 16))
  }

  func testPageNavigationMatchesDisplayedPage() {
    let first = TelegramPresentation.page(1, count: 17, size: 8)
    XCTAssertEqual(
      TelegramPresentation.navigation(first, command: "/projects").map { $0["callback_data"] },
      ["/projects 2"])
    let middle = TelegramPresentation.page(2, count: 17, size: 8)
    XCTAssertEqual(
      TelegramPresentation.navigation(middle, command: "/model").map { $0["callback_data"] },
      ["/model 1", "/model 3"])
    XCTAssertTrue(
      TelegramPresentation.navigation(
        TelegramPresentation.page(1, count: 0, size: 8), command: "/sessions"
      ).isEmpty)
  }

  func testFooterKeepsNavigationAndShowsOnlyRelevantSessionActions() {
    func actions(_ command: String, running: Bool, hasSession: Bool = true) -> [String] {
      TelegramPresentation.footer(command: command, running: running, hasSession: hasSession)
        .flatMap { $0 }.compactMap { $0["callback_data"] }
    }
    let busy = actions("/status", running: true)
    XCTAssertTrue(busy.contains("/stop"))
    XCTAssertFalse(busy.contains("/new"))
    XCTAssertFalse(busy.contains("/compact"))
    let idle = actions("model:1", running: false)
    XCTAssertTrue(idle.contains("/new"))
    XCTAssertTrue(idle.contains("/compact"))
    XCTAssertFalse(idle.contains("/stop"))
    let list = actions("/projects", running: false)
    XCTAssertFalse(list.contains("/new"))
    XCTAssertFalse(list.contains("/compact"))
    for command in ["/projects", "/sessions", "/status", "/model", "/thinking", "/usage"] {
      XCTAssertTrue(list.contains(command))
    }
    XCTAssertFalse(actions("/status", running: false, hasSession: false).contains("/new"))
    XCTAssertTrue(
      TelegramPresentation.footer(command: "/status", running: true, hasSession: true)
        .allSatisfy { $0.count <= 3 })
  }

  func testStopIsSeparatedFromNavigationAndExplainsQueueCancellation() {
    let rows = TelegramPresentation.footer(command: "/status", running: true, hasSession: true)
    let stop = rows.first { $0.contains { $0["callback_data"] == "/stop" } }
    XCTAssertEqual(stop?.count, 1)
    XCTAssertTrue(stop?.first?["text"]?.contains("取消排队") == true)
    XCTAssertTrue(rows.flatMap { $0 }.contains { $0["callback_data"] == "/queue" })
    let foreign = TelegramPresentation.footer(command: "/status", running: true, hasSession: false)
    XCTAssertFalse(foreign.flatMap { $0 }.contains { $0["callback_data"] == "/stop" })
  }

  @MainActor
  func testStatusDisplaysQueueOnlyWhenThereAreWaitingTasks() {
    let queued = TelegramControl.statusMessage(
      project: "demo", session: "任务", connection: .connected, busy: true,
      loading: false, detail: "", queuedCount: 3)
    XCTAssertTrue(queued.contains("排队  3 条"))
    let idle = TelegramControl.statusMessage(
      project: "demo", session: "任务", connection: .connected, busy: false,
      loading: false, detail: "")
    XCTAssertFalse(idle.contains("排队"))
  }
}

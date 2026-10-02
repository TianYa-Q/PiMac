import XCTest

@testable import PiMacApp

@MainActor
final class TelegramCardUpdatesTests: XCTestCase {
  // Nested types do not inherit the outer XCTestCase's actor isolation.
  // Serializing wait/fire avoids a lost wakeup between checking and registering.
  @MainActor
  private final class Signal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
      if fired { return }
      await withCheckedContinuation { waiters.append($0) }
    }

    func fire() {
      fired = true
      let pending = waiters
      waiters.removeAll()
      for waiter in pending { waiter.resume() }
    }
  }

  func testNavigationWinsOverInFlightAndQueuedTimerEdits() async {
    let updates = TelegramCardUpdates()
    let revision = updates.current(17)
    let started = Signal()
    let release = Signal()
    var trace: [String] = []
    let inFlight = updates.enqueue(17, revision: revision) {
      trace.append("timer-start")
      started.fire()
      await release.wait()
      trace.append("timer-end")
    }
    await started.wait()
    let stale = updates.enqueue(17, revision: revision) { trace.append("stale-timer") }
    let pageRevision = updates.advance(17)
    let page = updates.enqueue(17, revision: pageRevision) { trace.append("projects-page") }
    release.fire()
    let firstRan = await inFlight.value
    let staleRan = await stale.value
    let pageRan = await page.value
    XCTAssertTrue(firstRan)
    XCTAssertFalse(staleRan)
    XCTAssertTrue(pageRan)
    XCTAssertEqual(trace, ["timer-start", "timer-end", "projects-page"])
  }

  func testIndependentCardsDoNotBlockEachOther() async {
    let updates = TelegramCardUpdates()
    let started = Signal()
    let release = Signal()
    var trace: [String] = []
    let first = updates.enqueue(1, revision: updates.current(1)) {
      trace.append("first-start")
      started.fire()
      await release.wait()
      trace.append("first-end")
    }
    await started.wait()
    let second = updates.enqueue(2, revision: updates.current(2)) { trace.append("second") }
    let secondRan = await second.value
    XCTAssertTrue(secondRan)
    XCTAssertEqual(trace, ["first-start", "second"])
    release.fire()
    _ = await first.value
  }

  func testCompletionReadsLatestDeliveryStateAfterEarlierEditFinishes() async {
    let updates = TelegramCardUpdates()
    let revision = updates.current(17)
    let started = Signal()
    let release = Signal()
    var delivery: Bool? = nil
    var rendered = ""
    let first = updates.enqueue(17, revision: revision) {
      started.fire()
      await release.wait()
    }
    await started.wait()
    let completion = updates.enqueue(17, revision: revision) {
      rendered = TelegramPresentation.completionSummary(
        outcome: .completed, delivered: delivery, elapsed: "0 分 1 秒", queuedCount: 0)
    }
    delivery = true
    release.fire()
    _ = await first.value
    _ = await completion.value
    XCTAssertTrue(rendered.contains("结果已发送"))
    XCTAssertFalse(rendered.contains("正在发送"))
    XCTAssertTrue(rendered.contains("0 分 1 秒"))
  }

  func testResetInvalidatesQueuedEdits() async {
    let updates = TelegramCardUpdates()
    let revision = updates.current(17)
    let started = Signal()
    let release = Signal()
    var staleRan = false
    let first = updates.enqueue(17, revision: revision) {
      started.fire()
      await release.wait()
    }
    await started.wait()
    let stale = updates.enqueue(17, revision: revision) { staleRan = true }
    updates.reset()
    release.fire()
    _ = await first.value
    let performed = await stale.value
    XCTAssertFalse(performed)
    XCTAssertFalse(staleRan)
    XCTAssertNotEqual(updates.current(17), revision)
  }

  func testRetentionAndLateOldRevisionsCannotOverwriteNewPage() async {
    let updates = TelegramCardUpdates()
    let oldRevision = updates.current(17)
    updates.retain([])
    let newRevision = updates.current(17)
    var trace: [String] = []
    let fresh = updates.enqueue(17, revision: newRevision) { trace.append("new") }
    let stale = updates.enqueue(17, revision: oldRevision) { trace.append("old") }
    _ = await fresh.value
    let performed = await stale.value
    XCTAssertFalse(performed)
    XCTAssertEqual(trace, ["new"])
  }

  func testSendingStateDoesNotPrematurelyClaimDeliveryOrRetry() {
    let summary = TelegramPresentation.completionSummary(
      outcome: .stopped, delivered: nil, elapsed: "0 分 2 秒", queuedCount: 0)
    XCTAssertTrue(summary.hasPrefix("⏹ 任务已停止"))
    XCTAssertTrue(summary.contains("结果发送中"))
    XCTAssertFalse(summary.contains("已单独发送"))
    XCTAssertFalse(summary.contains("后台重试"))
  }
}

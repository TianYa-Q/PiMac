import Foundation
import Testing

@testable import PiMacApp

struct DevelopmentReloadStateTests {
  @Test func requiresContinuousIdleNotTimeSinceBuild() {
    var state = DevelopmentReloadState()
    let start = Date(timeIntervalSince1970: 100)
    let initial = state.observeIdle(true, now: start)
    let settled = state.observeIdle(true, now: start.addingTimeInterval(2))
    let busy = state.observeIdle(false, now: start.addingTimeInterval(3))
    let resumed = state.observeIdle(true, now: start.addingTimeInterval(10))
    let settledAgain = state.observeIdle(true, now: start.addingTimeInterval(12))
    #expect(!initial)
    #expect(settled)
    #expect(!busy)
    #expect(!resumed)
    #expect(settledAgain)
  }

  @Test func unfinishedBatchesBlockReloadUntilExplicitlyCompleted() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(!DevelopmentReloadState.editsPending(directory: directory))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let first = directory.appendingPathComponent("first.json")
    let second = directory.appendingPathComponent("second.json")
    try Data("unfinished".utf8).write(to: first)
    try Data("unfinished".utf8).write(to: second)
    #expect(DevelopmentReloadState.editsPending(directory: directory))
    try FileManager.default.removeItem(at: first)
    #expect(DevelopmentReloadState.editsPending(directory: directory))
    try FileManager.default.removeItem(at: second)
    #expect(!DevelopmentReloadState.editsPending(directory: directory))
    #expect(!DevelopmentReloadState.editsPending(directory: nil))
  }

  @Test func neverPublishesIdleDuringShutdownOrAfterFailure() {
    for phase in [DevelopmentReloadState.Phase.draining, .exiting, .failed] {
      var state = DevelopmentReloadState()
      state.begin()
      if phase == .exiting { state.readyToExit() }
      if phase == .failed { state.fail() }
      #expect(state.phase == phase)
      let initial = state.observeIdle(true, now: .now)
      let later = state.observeIdle(true, now: Date.now.addingTimeInterval(100))
      #expect(!initial)
      #expect(!later)
    }
  }
}

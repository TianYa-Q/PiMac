import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct WorkspaceRestoreTests {
  @Test func switchingProjectsPreservesTheSelectedNewSession() {
    let first = URL(fileURLWithPath: "/tmp/pi-workspace-first")
    let second = URL(fileURLWithPath: "/tmp/pi-workspace-second")

    #expect(WorkspaceModel.shouldDiscardDraftOnTabSwitch(from: first, to: second) == false)
    #expect(WorkspaceModel.shouldDiscardDraftOnTabSwitch(from: second, to: first) == false)
    #expect(WorkspaceModel.shouldDiscardDraftOnTabSwitch(from: first, to: first))
  }

  @Test func restoresOnlyWithinFiveMinutesOfClosing() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    #expect(WorkspaceModel.shouldRestoreLastSession(closedAt: nil, now: now) == false)
    #expect(WorkspaceModel.shouldRestoreLastSession(closedAt: now, now: now))
    #expect(WorkspaceModel.shouldRestoreLastSession(closedAt: now.addingTimeInterval(-299), now: now))
    #expect(WorkspaceModel.shouldRestoreLastSession(closedAt: now.addingTimeInterval(-300), now: now))
    #expect(WorkspaceModel.shouldRestoreLastSession(closedAt: now.addingTimeInterval(-301), now: now) == false)
    #expect(WorkspaceModel.shouldRestoreLastSession(closedAt: now.addingTimeInterval(1), now: now) == false)
  }
}

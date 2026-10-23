import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ThreadGoalTests {
  private let goal: [String: Any] = [
    "objective": "Export CSV", "status": "active", "tokensUsed": 12, "timeUsedSeconds": 3,
  ]

  @Test func validatesGoalWithoutTreatingCorruptionAsEmpty() {
    #expect(ThreadGoal.State.read(nil, driver: nil) == .none)
    #expect(ThreadGoal.State.read(NSNull(), driver: "pi") == .none)
    for status in ["active", "paused", "blocked", "usage_limited", "budget_limited", "complete"] {
      var value = goal
      value["status"] = status
      guard case .available(let parsed, driver: "pi") = ThreadGoal.State.read(value, driver: "pi")
      else {
        Issue.record("合法目标未被解析")
        continue
      }
      #expect(parsed.status.rawValue == status)
    }
    for (key, value) in [
      ("objective", " " as Any), ("status", "done"), ("tokensUsed", -1),
      ("tokensUsed", true), ("timeUsedSeconds", 1.5), ("tokenBudget", -1),
    ] {
      var invalid = goal
      invalid[key] = value
      #expect(ThreadGoal.State.read(invalid, driver: "pi") == .invalid)
    }
    #expect(ThreadGoal.State.read("broken", driver: nil) == .invalid)
  }

  @Test func onlyActiveProviderGoalIsProjectedAndEmptyStateClearsOldGoal() throws {
    let app = AppModel(continueLastSession: false, restoreLastProjectOnLaunch: false)
    app.currentSessionPath = "t3:thread"
    app.composerText = "Unsent draft"
    func detail(_ activeID: String?) -> [String: Any] {
      T3V2Presentation.detail([
        "projection": [
          "thread": ["id": "thread", "activeProviderThreadId": activeID as Any? ?? NSNull()],
          "providerThreads": [
            ["id": "old", "driver": "codex", "goal": goal],
            ["id": "new", "driver": "pi", "goal": NSNull()],
          ],
        ]
      ])
    }
    app.apply(detail("old"))
    guard case .available(let parsed, driver: "codex") = app.goalState else {
      Issue.record("未展示当前 Provider 的目标")
      return
    }
    #expect(parsed.objective == "Export CSV")
    app.apply(detail("new"))
    #expect(app.goalState == .none)
    app.apply(detail("missing"))
    #expect(app.goalState == .none)
    app.apply(detail(nil))
    #expect(app.goalState == .none)
    #expect(app.composerText == "Unsent draft")
  }

  @Test func goalDoesNotLeakAcrossThreadSnapshotsOrDisconnect() {
    let app = AppModel(continueLastSession: false, restoreLastProjectOnLaunch: false)
    app.currentSessionPath = "t3:thread"
    app.apply(["thread": ["id": "thread", "goal": goal, "goalDriver": "pi"]])
    let previous = app.goalState
    app.apply(["thread": ["id": "another", "goal": NSNull()]])
    #expect(app.goalState == previous)
    app.disconnect()
    #expect(app.goalState == .none)
  }
}

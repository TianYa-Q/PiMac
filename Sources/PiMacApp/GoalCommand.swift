import Foundation

/// 原生层只表达用户意图；持久化和续跑交给 @schovest/pi-goal。
enum GoalCommand: CaseIterable {
  case progress, pause, resume, archive

  var text: String {
    switch self {
    case .progress: "/goal status"
    case .pause: "/goal pause"
    case .resume: "/goal resume"
    case .archive: "/goal clear"
    }
  }

  func isAvailable(in state: ThreadGoal.State) -> Bool {
    guard case .available(let goal, driver: "pi") = state else { return false }
    switch self {
    case .pause: return goal.status == .active
    case .resume: return goal.status != .active && goal.status != .complete
    default: return true
    }
  }
}

struct GoalRevision {
  let original: ThreadGoal

  func command(objective: String, state: ThreadGoal.State) -> String? {
    let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
    guard case .available(let current, driver: "pi") = state,
      current.objective == original.objective, current.status != .complete,
      !text.isEmpty, text.utf16.count <= 4000,
      text != original.objective.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }
    return "/goal edit \(text)"
  }
}

import Foundation

/// 原生层只表达用户意图；目标存储、确认和续跑仍交给 pi-goal-x。
enum GoalCommand: CaseIterable {
  case progress, pause, resume, focus, settings, archive

  var text: String {
    switch self {
    case .progress: "/goal-status"
    case .pause: "/goal-pause"
    case .resume: "/goal-resume"
    case .focus: "/goal-focus"
    case .settings: "/goal-settings"
    case .archive: "/goal-clear"
    }
  }

  func isAvailable(in state: ThreadGoal.State) -> Bool {
    switch (self, state) {
    case (.focus, .none), (.settings, .none): return true
    case (_, .available(let goal, driver: "pi")):
      switch self {
      case .pause: return goal.status == .active
      case .resume: return goal.status != .active && goal.status != .complete
      default: return true
      }
    default: return false
    }
  }
}

struct GoalRevision {
  let original: ThreadGoal

  func command(objective: String, state: ThreadGoal.State) -> String? {
    let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
    guard case .available(let current, driver: "pi") = state,
      current.objective == original.objective, current.status != .complete,
      !text.isEmpty, text != original.objective.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }
    // tweak 是修订提案而非直接写盘。提交完整正文，避免模型把删除的要求自行补回。
    return
      "/goal-tweak 将目标正文替换为以下完整内容。请按修订流程讨论并确认，不要擅自保留已从正文删除的要求；如与现有计划或验收标准冲突，请一并指出供我确认。\n\n\(text)"
  }
}

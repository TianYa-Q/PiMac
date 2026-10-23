import Foundation

/// 目标只来自 Server 的 active provider thread；这里不保存任务或调度续跑。
struct ThreadGoal: Decodable, Equatable {
  enum Status: String, Decodable {
    case active, paused, blocked
    case usageLimited = "usage_limited"
    case budgetLimited = "budget_limited"
    case complete

    var title: String {
      switch self {
      case .active: "进行中"
      case .paused: "已暂停"
      case .blocked: "等待处理"
      case .usageLimited: "用量受限"
      case .budgetLimited: "预算受限"
      case .complete: "已完成"
      }
    }
  }

  let objective: String
  let status: Status
  let tokensUsed: Int?
  let timeUsedSeconds: Int?
  let tokenBudget: Int?

  enum State: Equatable {
    case none
    case available(ThreadGoal, driver: String?)
    case invalid

    static func read(_ value: Any?, driver: String?) -> Self {
      guard let value, !(value is NSNull) else { return .none }
      do {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        let goal = try JSONDecoder().decode(ThreadGoal.self, from: data)
        guard !goal.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          [goal.tokensUsed, goal.timeUsedSeconds, goal.tokenBudget].allSatisfy({
            $0.map { $0 >= 0 } ?? true
          })
        else { return .invalid }
        return .available(goal, driver: driver)
      } catch { return .invalid }
    }
  }
}

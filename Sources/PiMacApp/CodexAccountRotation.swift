import Foundation

/// Allocate weekly quota by sustainable remaining percent/day, not account name.
enum CodexAccountRotation {
  static func nextAccount(
    in accounts: [CodexAccountStatus], now: Date = Date(), allowRebalance: Bool = true
  ) -> String? {
    guard let active = accounts.first(where: \.isActive),
      let activeRemaining = remaining(active, seconds: 18_000)
    else { return nil }
    let urgent = activeRemaining < 5
    guard urgent || allowRebalance else { return nil }
    let candidates = accounts.filter {
      !$0.isActive && !$0.isHidden && $0.error == nil
        && (remaining($0, seconds: 18_000) ?? 0) > 5
        && (remaining($0, seconds: 604_800) ?? 100) > 5
    }
    // Missing weekly telemetry retains the old natural-order fallback. Known weekly
    // telemetry wins; exhausted weekly windows are never eligible.
    let ranked = candidates.sorted {
      let lhs = budget($0, now: now), rhs = budget($1, now: now)
      let lhsTier = lhs.map { $0.paced ? 2 : 1 } ?? 0
      let rhsTier = rhs.map { $0.paced ? 2 : 1 } ?? 0
      if lhsTier != rhsTier { return lhsTier > rhsTier }
      if lhs?.rate != rhs?.rate { return (lhs?.rate ?? -1) > (rhs?.rate ?? -1) }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    guard let best = ranked.first else { return nil }
    if urgent { return best.name }
    // Rebalance only at idle boundaries (caller), with hysteresis to avoid churn.
    guard let currentBudget = budget(active, now: now),
      let nextBudget = budget(best, now: now), nextBudget.paced,
      (!currentBudget.paced || nextBudget.rate > currentBudget.rate * 1.5)
    else { return nil }
    return best.name
  }

  private static func window(_ account: CodexAccountStatus, seconds: Double) -> CodexUsageWindow? {
    [account.primary, account.secondary].compactMap { $0 }.first { $0.windowSeconds == seconds }
  }

  private static func remaining(_ account: CodexAccountStatus, seconds: Double) -> Double? {
    guard let value = window(account, seconds: seconds)?.remainingPercent,
      value.isFinite, (0...100).contains(value)
    else { return nil }
    return value
  }

  private static func budget(_ account: CodexAccountStatus, now: Date) -> (rate: Double, paced: Bool)? {
    guard let value = remaining(account, seconds: 604_800),
      let reset = window(account, seconds: 604_800)?.resetAt
    else { return nil }
    let seconds = reset.timeIntervalSince(now)
    // Stale or impossible reset timestamps must not gain priority.
    guard seconds.isFinite, seconds > 0, seconds <= 604_800 else { return nil }
    let days = seconds / 86_400
    // A 15-point burst allowance above linear consumption; protect accounts that
    // burned their weekly budget too early. A six-hour floor bounds reset urgency.
    return (max(0, value - 5) / max(0.25, days), value >= 100 * days / 7 - 15)
  }
}

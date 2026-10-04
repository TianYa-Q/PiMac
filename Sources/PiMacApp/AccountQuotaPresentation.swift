import Foundation

/// Pure display policy. Filtering/sorting never changes visibility settings or auth.
enum AccountQuotaPresentation {
  enum Filter: String, CaseIterable, Identifiable {
    case all, visible, attention
    var id: String { rawValue }
    var title: String {
      switch self {
      case .all: "全部"
      case .visible: "未隐藏"
      case .attention: "需关注"
      }
    }
  }

  enum Sort: String, CaseIterable, Identifiable {
    case name, remaining, reset
    var id: String { rawValue }
    var title: String {
      switch self {
      case .name: "账户名称"
      case .remaining: "剩余额度优先"
      case .reset: "即将重置优先"
      }
    }
  }

  static func needsAttention(_ account: CodexAccountStatus, now: Date, maxAge: TimeInterval) -> Bool
  {
    guard !account.isHidden else { return false }
    return account.error != nil || remaining(account) == nil
      || AccountUsageSnapshot.freshness(capturedAt: account.capturedAt, now: now, maxAge: maxAge)
        != .fresh
      || (remaining(account) ?? 100) < 20
  }

  static func matches(_ text: String, query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty || text.localizedStandardContains(query)
  }

  static func accounts(
    _ accounts: [CodexAccountStatus], query: String, filter: Filter, sort: Sort,
    now: Date, maxAge: TimeInterval
  ) -> [CodexAccountStatus] {
    accounts.filter { account in
      matches(account.name, query: query)
        && (filter != .visible || !account.isHidden)
        && (filter != .attention || needsAttention(account, now: now, maxAge: maxAge))
    }.sorted { left, right in
      if left.isActive != right.isActive { return left.isActive }
      switch sort {
      case .name: break
      case .remaining:
        let l = reliableRemaining(left, now: now, maxAge: maxAge) ?? -1
        let r = reliableRemaining(right, now: now, maxAge: maxAge) ?? -1
        if l != r { return l > r }
      case .reset:
        let l = nextReset(left, now: now) ?? .distantFuture
        let r = nextReset(right, now: now) ?? .distantFuture
        if l != r { return l < r }
      }
      let comparison = left.name.localizedStandardCompare(right.name)
      return comparison == .orderedSame ? left.name < right.name : comparison == .orderedAscending
    }
  }

  static func showsGemini(
    _ status: GeminiUsageStatus, query: String, filter: Filter, now: Date, maxAge: TimeInterval
  ) -> Bool {
    guard status.isConfigured, matches("Antigravity Gemini", query: query) else { return false }
    return filter != .attention || status.error != nil || status.quotas.isEmpty
      || status.quotas.contains { $0.remainingPercent < 20 }
      || AccountUsageSnapshot.freshness(capturedAt: status.capturedAt, now: now, maxAge: maxAge)
        != .fresh
  }

  private static func remaining(_ account: CodexAccountStatus) -> Double? {
    [account.primary, account.secondary].compactMap { $0?.remainingPercent }
      .filter { $0.isFinite && (0...100).contains($0) }.min()
  }

  private static func reliableRemaining(
    _ account: CodexAccountStatus, now: Date, maxAge: TimeInterval
  ) -> Double? {
    guard !account.isHidden, account.error == nil,
      AccountUsageSnapshot.freshness(capturedAt: account.capturedAt, now: now, maxAge: maxAge)
        == .fresh
    else { return nil }
    return remaining(account)
  }

  private static func nextReset(_ account: CodexAccountStatus, now: Date) -> Date? {
    guard !account.isHidden, account.error == nil else { return nil }
    return [account.primary, account.secondary].compactMap { $0?.resetAt }.filter { $0 > now }.min()
  }
}

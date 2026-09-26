import Foundation

/// Uses the same natural name ordering as the account list, wrapping after the last account.
enum CodexAccountRotation {
  static func nextAccount(in accounts: [CodexAccountStatus]) -> String? {
    let ordered = accounts.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    guard let index = ordered.firstIndex(where: \.isActive),
      let remaining = fiveHourRemaining(ordered[index]), remaining < 5,
      ordered.count > 1
    else { return nil }

    for offset in 1..<ordered.count {
      let candidate = ordered[(index + offset) % ordered.count]
      guard !candidate.isHidden, candidate.error == nil,
        let remaining = fiveHourRemaining(candidate), remaining > 5
      else { continue }
      return candidate.name
    }
    return nil
  }

  private static func fiveHourRemaining(_ account: CodexAccountStatus) -> Double? {
    let window = [account.primary, account.secondary].compactMap { $0 }.first {
      $0.windowSeconds == 5 * 60 * 60
    }
    guard let remaining = window?.remainingPercent, remaining.isFinite,
      (0...100).contains(remaining)
    else { return nil }
    return remaining
  }
}

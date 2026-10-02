import Foundation
import Testing

@testable import PiMacApp

struct CodexAccountRotationTests {
  @Test func strictThresholdsAndWraparound() {
    #expect(
      CodexAccountRotation.nextAccount(in: [account("A", 5, active: true), account("B", 80)]) == nil
    )
    #expect(
      CodexAccountRotation.nextAccount(in: [
        account("A", 4.9, active: true), account("B", 5), account("C", 5.1),
      ]) == "C")
    #expect(
      CodexAccountRotation.nextAccount(in: [account("A", 50), account("B", 0, active: true)]) == "A"
    )
  }

  @Test func skipsUnavailableAccounts() {
    let accounts = [
      account("A", 1, active: true), account("B", 90, hidden: true),
      account("C", 90, error: "Unavailable"), account("D", nil), account("E", 10),
    ]
    #expect(CodexAccountRotation.nextAccount(in: accounts) == "E")
    #expect(CodexAccountRotation.nextAccount(in: Array(accounts.dropLast())) == nil)
    #expect(CodexAccountRotation.nextAccount(in: [account("A", 0, active: true)]) == nil)
    #expect(CodexAccountRotation.nextAccount(in: [account("A", 0), account("B", 80)]) == nil)
  }

  @Test func usesFiveHourWindowOnlyAndNaturalOrder() {
    #expect(
      CodexAccountRotation.nextAccount(in: [
        account("A", 1, active: true, seconds: 604800), account("B", 80),
      ]) == nil)
    #expect(
      CodexAccountRotation.nextAccount(in: [
        account("A", 1, active: true), account("B", 80, seconds: 604800),
      ]) == nil)
    #expect(
      CodexAccountRotation.nextAccount(in: [
        account("A10", 80), account("A1", 1, active: true), account("A2", 6),
      ]) == "A2")
    #expect(
      CodexAccountRotation.nextAccount(in: [account("A", 1, active: true), account("B", .nan)])
        == nil)
  }

  @Test func weeklyAllocationPrioritizesResetWithoutBurningEarly() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let active = account("Active", 1, active: true)
    let nearReset = weekly("Near", remaining: 40, days: 1, now: now)
    let fresh = weekly("Fresh", remaining: 95, days: 6, now: now)
    #expect(CodexAccountRotation.nextAccount(in: [active, fresh, nearReset], now: now) == "Near")
    // Only 40% remains with six days to go: preserve this account despite ample 5h.
    let overused = weekly("Overused", remaining: 40, days: 6, now: now)
    #expect(CodexAccountRotation.nextAccount(in: [active, overused, fresh], now: now) == "Fresh")
    let exhausted = weekly("Empty", remaining: 4, days: 0.1, now: now)
    #expect(CodexAccountRotation.nextAccount(in: [active, exhausted], now: now) == nil)
  }

  @Test func weeklyRebalanceIsIdleOnlyAndHasHysteresis() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let active = weekly("Active", remaining: 90, days: 6, now: now, active: true)
    let near = weekly("Near", remaining: 40, days: 1, now: now)
    #expect(CodexAccountRotation.nextAccount(in: [active, near], now: now) == "Near")
    #expect(CodexAccountRotation.nextAccount(
      in: [active, near], now: now, allowRebalance: false) == nil)
    let similar = weekly("Similar", remaining: 95, days: 6, now: now)
    #expect(CodexAccountRotation.nextAccount(in: [active, similar], now: now) == nil)
    let stale = weekly("Stale", remaining: 100, days: -1, now: now)
    #expect(CodexAccountRotation.nextAccount(in: [active, stale], now: now) == nil)
  }

  private func weekly(
    _ name: String, remaining: Double, days: Double, now: Date, active: Bool = false
  ) -> CodexAccountStatus {
    CodexAccountStatus(
      name: name, isActive: active, isDefault: false, isHidden: false,
      primary: CodexUsageWindow(remainingPercent: 80, resetAt: nil, windowSeconds: 18_000),
      secondary: CodexUsageWindow(
        remainingPercent: remaining, resetAt: now.addingTimeInterval(days * 86_400),
        windowSeconds: 604_800),
      resetCredits: nil, error: nil)
  }

  private func account(
    _ name: String, _ remaining: Double?, active: Bool = false,
    hidden: Bool = false, error: String? = nil, seconds: Double = 18000
  ) -> CodexAccountStatus {
    CodexAccountStatus(
      name: name, isActive: active, isDefault: false, isHidden: hidden,
      primary: remaining.map {
        CodexUsageWindow(remainingPercent: $0, resetAt: nil, windowSeconds: seconds)
      },
      secondary: nil, resetCredits: nil, error: error)
  }
}

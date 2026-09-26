import Testing
@testable import PiMacApp

struct CodexAccountRotationTests {
  @Test func strictThresholdsAndWraparound() {
    #expect(CodexAccountRotation.nextAccount(in: [account("A", 5, active: true), account("B", 80)]) == nil)
    #expect(CodexAccountRotation.nextAccount(in: [account("A", 4.9, active: true), account("B", 5), account("C", 5.1)]) == "C")
    #expect(CodexAccountRotation.nextAccount(in: [account("A", 50), account("B", 0, active: true)]) == "A")
  }

  @Test func skipsUnavailableAccounts() {
    let accounts = [account("A", 1, active: true), account("B", 90, hidden: true),
      account("C", 90, error: "Unavailable"), account("D", nil), account("E", 10)]
    #expect(CodexAccountRotation.nextAccount(in: accounts) == "E")
    #expect(CodexAccountRotation.nextAccount(in: Array(accounts.dropLast())) == nil)
    #expect(CodexAccountRotation.nextAccount(in: [account("A", 0, active: true)]) == nil)
    #expect(CodexAccountRotation.nextAccount(in: [account("A", 0), account("B", 80)]) == nil)
  }

  @Test func usesFiveHourWindowOnlyAndNaturalOrder() {
    #expect(CodexAccountRotation.nextAccount(in: [account("A", 1, active: true, seconds: 604800), account("B", 80)]) == nil)
    #expect(CodexAccountRotation.nextAccount(in: [account("A", 1, active: true), account("B", 80, seconds: 604800)]) == nil)
    #expect(CodexAccountRotation.nextAccount(in: [account("A10", 80), account("A1", 1, active: true), account("A2", 6)]) == "A2")
    #expect(CodexAccountRotation.nextAccount(in: [account("A", 1, active: true), account("B", .nan)]) == nil)
  }

  private func account(_ name: String, _ remaining: Double?, active: Bool = false,
    hidden: Bool = false, error: String? = nil, seconds: Double = 18000
  ) -> CodexAccountStatus {
    CodexAccountStatus(name: name, isActive: active, isDefault: false, isHidden: hidden,
      primary: remaining.map { CodexUsageWindow(remainingPercent: $0, resetAt: nil, windowSeconds: seconds) },
      secondary: nil, resetCredits: nil, error: error)
  }
}

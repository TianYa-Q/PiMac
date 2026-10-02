import Foundation
import Testing
@testable import PiMacApp

struct AccountQuotaRefreshPolicyTests {
  @Test func frequentSnapshotsAreThrottled() {
    var policy = AccountQuotaRefreshPolicy()
    let generation = UUID()
    let start = ContinuousClock.now
    func attempt(_ seconds: Int, active: Bool) -> Bool {
      policy.shouldRefresh(
        generation: generation, provider: .chatGPT, isActive: active,
        now: start.advanced(by: .seconds(seconds)))
    }
    #expect(attempt(0, active: false))
    #expect(!attempt(1, active: false))
    #expect(!attempt(179, active: false))
    #expect(attempt(180, active: false))
    #expect(!attempt(239, active: true))
    #expect(attempt(240, active: true))
    #expect(!attempt(241, active: true))
  }

  @Test func manualRefreshAndScopeChangesBypassThrottle() {
    var policy = AccountQuotaRefreshPolicy()
    let generation = UUID()
    let now = ContinuousClock.now
    func attempt(_ provider: AccountUsageProvider, scope: UUID? = nil, force: Bool = false) -> Bool {
      policy.shouldRefresh(
        generation: scope ?? generation, provider: provider, isActive: false, force: force, now: now)
    }
    #expect(attempt(.chatGPT))
    #expect(attempt(.chatGPT, force: true))
    #expect(!attempt(.chatGPT))
    #expect(attempt(.antigravity))
    #expect(attempt(.antigravity, scope: UUID()))
  }
}

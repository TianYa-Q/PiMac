import Foundation
import Testing

@testable import PiMacApp

struct AccountQuotaPresentationTests {
  private func account(
    _ name: String, active: Bool = false, hidden: Bool = false, error: String? = nil
  ) -> CodexAccountStatus {
    CodexAccountStatus(
      name: name, isActive: active, isDefault: false, isHidden: hidden,
      primary: nil, secondary: nil, resetCredits: nil, error: error, capturedAt: nil)
  }

  @Test func hiddenAccountsAreExcludedWithActiveFirstThenNaturalNameOrder() {
    let rows = [
      account("work10"), account("hidden", hidden: true), account("work2"),
      account("failed", error: "offline"), account("current", active: true),
    ]
    #expect(
      AccountQuotaPresentation.accounts(rows).map(\.name)
        == ["current", "failed", "work2", "work10"])
    #expect(rows[1].isHidden)
  }

  @Test func onlyConfiguredActiveGeminiIsPlacedFirst() {
    for configured in [false, true] {
      for active in [false, true] {
        let gemini = GeminiUsageStatus(
          isConfigured: configured, isActive: active, quotas: [], error: nil)
        #expect(AccountQuotaPresentation.showsGeminiFirst(gemini) == (configured && active))
      }
    }
    #expect(!AccountQuotaPresentation.showsGeminiFirst(nil))
  }

  @Test func hiddenActiveAccountAndAllHiddenAccountsAreExcluded() {
    #expect(AccountQuotaPresentation.accounts([account("current", active: true, hidden: true), account("work")]).map(\.name) == ["work"])
    #expect(AccountQuotaPresentation.accounts([account("only", active: true, hidden: true)]).isEmpty)
  }

  @Test func emptyAccountsRemainEmpty() {
    #expect(AccountQuotaPresentation.accounts([]).isEmpty)
  }
}

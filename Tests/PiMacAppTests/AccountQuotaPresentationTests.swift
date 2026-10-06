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

  @Test func allAccountsRemainVisibleWithActiveFirstThenNaturalNameOrder() {
    let rows = [
      account("work10"), account("hidden", hidden: true), account("work2"),
      account("failed", error: "offline"), account("current", active: true),
    ]
    #expect(
      AccountQuotaPresentation.accounts(rows).map(\.name)
        == ["current", "failed", "hidden", "work2", "work10"])
    #expect(rows[1].isHidden)
  }

  @Test func emptyAccountsRemainEmpty() {
    #expect(AccountQuotaPresentation.accounts([]).isEmpty)
  }
}

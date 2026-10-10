import Foundation

/// Display all accounts with the active account first, then by name.
enum AccountQuotaPresentation {
  static func showsGeminiFirst(_ gemini: GeminiUsageStatus?) -> Bool {
    gemini?.isConfigured == true && gemini?.isActive == true
  }

  static func accounts(_ accounts: [CodexAccountStatus]) -> [CodexAccountStatus] {
    accounts.sorted { left, right in
      if left.isActive != right.isActive { return left.isActive }
      let comparison = left.name.localizedStandardCompare(right.name)
      return comparison == .orderedSame ? left.name < right.name : comparison == .orderedAscending
    }
  }
}

import Foundation

/// 隐藏只影响额度展示；账户管理仍从完整账户存储读取。
enum AccountQuotaPresentation {
  static func showsGeminiFirst(_ gemini: GeminiUsageStatus?) -> Bool {
    gemini?.isConfigured == true && gemini?.isActive == true
  }

  static func accounts(_ accounts: [CodexAccountStatus]) -> [CodexAccountStatus] {
    accounts.filter { !$0.isHidden }.sorted { left, right in
      if left.isActive != right.isActive { return left.isActive }
      let comparison = left.name.localizedStandardCompare(right.name)
      return comparison == .orderedSame ? left.name < right.name : comparison == .orderedAscending
    }
  }
}

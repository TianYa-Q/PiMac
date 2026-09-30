/// Providers with isolated account-usage credentials and quota snapshots.
enum AccountUsageProvider: String, Sendable {
  case legacyCodex = "openai-codex"
  case chatGPT = "openai"

  init?(modelID: String) {
    guard let separator = modelID.firstIndex(of: "/") else { return nil }
    self.init(rawValue: String(modelID[..<separator]))
  }
}

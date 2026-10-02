/// Providers with isolated account-usage credentials and quota snapshots.
enum AccountUsageProvider: String, Sendable {
  case legacyCodex = "openai-codex"
  case chatGPT = "openai"
  case antigravity = "antigravity"

  var credentialLabel: String {
    switch self {
    case .legacyCodex: "Codex Legacy"
    case .chatGPT: "Codex 新版 · ChatGPT"
    case .antigravity: "Antigravity"
    }
  }

  init?(modelID: String) {
    guard let separator = modelID.firstIndex(of: "/") else { return nil }
    self.init(rawValue: String(modelID[..<separator]))
  }
}

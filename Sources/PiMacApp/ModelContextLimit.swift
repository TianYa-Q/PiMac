import Foundation

struct ModelContextSettings: Decodable, Equatable {
  let overrides: [String: Int]
  let defaults: [String: Int]

  static let empty = ModelContextSettings(overrides: [:], defaults: [:])
}

/// 空输入表示移除手工覆盖；正整数是总上下文预算，不是输出上限或压缩后保留量。
enum ModelContextLimit {
  static let maximumTokens = 9_007_199_254_740_991  // 与 Server 的 JS safe integer 边界一致。

  enum ValidationError: LocalizedError {
    case invalidTokens

    var errorDescription: String? { "请输入正整数 token 数，或留空以恢复 Pi 默认。" }
  }

  static func parse(_ text: String) throws -> Int? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return nil }
    guard value.utf8.allSatisfy({ (48...57).contains($0) }),
      let tokens = Int(value)
    else { throw ValidationError.invalidTokens }
    try validate(tokens)
    return tokens
  }

  /// 文本输入与程序调用共用边界校验，nil 明确表示恢复默认值。
  static func validate(_ tokens: Int?) throws {
    if let tokens, tokens <= 0 || tokens > maximumTokens {
      throw ValidationError.invalidTokens
    }
  }
}

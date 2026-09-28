import Foundation

/// Give the compact account-usage notification readable labels without touching other notices.
enum QuotaNotificationFormatter {
  static func format(_ text: String) -> String {
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    guard !lines.isEmpty else { return text }
    var groups: [String] = []
    for line in lines {
      let parts = line.split(separator: "·", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard parts.count == 2,
        let colon = parts[0].firstIndex(where: { $0 == ":" || $0 == "：" })
      else { return text }
      let name = String(parts[0][..<colon]).trimmingCharacters(in: .whitespaces)
      let first = String(parts[0][parts[0].index(after: colon)...]).trimmingCharacters(
        in: .whitespaces)
      guard !name.isEmpty,
        let short = window(first, expected: "5h", label: "5 小时"),
        let long = window(parts[1], expected: "7d", label: "7 天")
      else { return text }
      groups.append("**\(name)**\n- \(short)\n- \(long)")
    }
    return groups.joined(separator: "\n\n")
  }

  private static func window(_ raw: String, expected: String, label: String) -> String? {
    guard raw.hasPrefix(expected + " "), let percent = raw.firstIndex(of: "%") else {
      return nil
    }
    let value = raw[raw.index(raw.startIndex, offsetBy: expected.count)..<percent]
      .trimmingCharacters(in: .whitespaces)
    guard Double(value) != nil else { return nil }
    let tail = raw[raw.index(after: percent)...].trimmingCharacters(in: .whitespaces)
    if tail.isEmpty { return "\(label)：剩余 \(value)%" }

    // The extension uses a clock/refresh symbol before the reset countdown.
    guard let start = tail.firstIndex(where: \.isNumber) else { return nil }
    let countdown = tail[start...].trimmingCharacters(in: .whitespaces)
    let tokens = countdown.split(separator: " ")
    guard !tokens.isEmpty,
      tokens.allSatisfy({ $0.range(of: #"^\d+[dhm]$"#, options: .regularExpression) != nil })
    else { return nil }
    let localized = tokens.map { token in
      let unit = token.last!
      let number = token.dropLast()
      let units: [Character: String] = ["d": "天", "h": "小时", "m": "分钟"]
      return "\(number)\(units[unit]!)"
    }.joined(separator: " ")
    return "\(label)：剩余 \(value)% · \(localized)后重置"
  }
}

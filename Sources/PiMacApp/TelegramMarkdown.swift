import Foundation

/// Telegram does not parse Markdown unless a parse mode is supplied. Render the common
/// inline constructs as Telegram HTML; escape everything else so model output cannot
/// accidentally create unsupported HTML entities or tags.
enum TelegramMarkdown {
  static func html(_ text: String) -> String {
    var result: [String] = []
    var inFence = false
    for line in text.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        if inFence {
          result.append("</pre>")
        } else {
          result.append("<pre>")
        }
        inFence.toggle()
      } else if inFence {
        result.append(escape(line))
      } else {
        var content = line[...]
        if content.hasPrefix("#"), let end = content.firstIndex(where: { $0 != "#" }),
          content[end] == " "
        {
          content = content[content.index(after: end)...]
          result.append("<b>\(inline(content))</b>")
        } else {
          result.append(inline(content))
        }
      }
    }
    if inFence { result.append("</pre>") }
    return result.joined(separator: "\n")
  }

  private static func inline(_ content: Substring) -> String {
    var result = ""
    var cursor = content.startIndex
    while cursor < content.endIndex {
      let tail = content[cursor...]
      if tail.hasPrefix("\\"),
        let next = content.index(cursor, offsetBy: 1, limitedBy: content.endIndex),
        next < content.endIndex
      {
        result += escape(String(content[next]))
        cursor = content.index(after: next)
        continue
      }
      if tail.hasPrefix("["), let close = tail.firstIndex(of: "]"),
        close < content.endIndex, content[content.index(after: close)...].hasPrefix("("),
        let end = content[content.index(close, offsetBy: 2)...].firstIndex(of: ")")
      {
        let urlText = String(content[content.index(close, offsetBy: 2)..<end])
        if let url = URL(string: urlText),
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
        {
          result +=
            "<a href=\"\(escape(urlText))\">\(inline(content[content.index(after: cursor)..<close]))</a>"
          cursor = content.index(after: end)
          continue
        }
      }
      var matched = false
      for (marker, tag) in [
        ("**", "b"), ("__", "b"), ("~~", "s"), ("`", "code"), ("*", "i"), ("_", "i"),
      ] {
        guard tail.hasPrefix(marker),
          let start = content.index(cursor, offsetBy: marker.count, limitedBy: content.endIndex),
          start < content.endIndex,
          let end = content[start...].range(of: marker)?.lowerBound, end > start
        else { continue }
        let inner = content[start..<end]
        result += "<\(tag)>\(tag == "code" ? escape(String(inner)) : inline(inner))</\(tag)>"
        cursor = content.index(end, offsetBy: marker.count)
        matched = true
        break
      }
      if matched { continue }
      result += escape(String(content[cursor]))
      cursor = content.index(after: cursor)
    }
    return result
  }

  private static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }
}

import Foundation

/// Only explicit Markdown file references are downloaded, never arbitrary prose paths
/// or remote URLs. The server resolves relative paths in the thread's workspace.
enum T3ReplyImageLinks {
  static func mimeType(_ path: String) -> String? {
    switch (path as NSString).pathExtension.lowercased() {
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "gif": "image/gif"
    case "webp": "image/webp"
    default: nil
    }
  }

  static func path(for url: URL) -> String? {
    guard url.host == nil || url.host == "", url.query == nil, url.fragment == nil,
      url.scheme == nil || url.scheme == "file"
    else { return nil }
    let path =
      url.isFileURL ? url.path : url.relativeString.removingPercentEncoding ?? url.relativeString
    guard !path.isEmpty, path.utf8.count <= 1024, !path.contains("\0"), mimeType(path) != nil else {
      return nil
    }
    return path
  }

  static func paths(in text: String) -> [String] {
    // Skip fenced code and inline code: examples must not read files automatically.
    var result: [String] = []
    var fenced = false
    for line in text.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fenced.toggle()
        continue
      }
      if fenced { continue }
      let source = line.replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression)
      guard
        let expression = try? NSRegularExpression(
          pattern: #"!?\[[^\]\n]*\]\(\s*(<[^>\n]+>|[^\s)]+)(?:\s+\"[^\"]*\")?\s*\)"#)
      else { continue }
      let range = NSRange(source.startIndex..., in: source)
      for match in expression.matches(in: source, range: range) {
        guard let range = Range(match.range(at: 1), in: source) else { continue }
        let target = String(source[range]).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard let url = URL(string: target), let path = path(for: url), !result.contains(path)
        else { continue }
        result.append(path)
        if result.count == 8 { return result }
      }
    }
    return result
  }
}

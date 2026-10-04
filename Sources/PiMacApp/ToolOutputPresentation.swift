import Foundation

/// Bound native glyph layout independently of the transcript's retained output.
struct ToolOutputPresentation: Equatable {
  static let maximumBytes = 128 * 1024
  static let maximumLines = 2000
  static let maximumMatches = 1000

  let text: String
  let isTruncated: Bool
  let lineCount: Int

  init(
    text source: String, maximumBytes: Int = Self.maximumBytes,
    maximumLines: Int = Self.maximumLines
  ) {
    precondition(maximumBytes > 0 && maximumLines > 0)
    var end = source.unicodeScalars.startIndex
    var bytes = 0
    var lines = 1
    var previousWasCR = false
    let newlines = CharacterSet.newlines
    while end < source.unicodeScalars.endIndex {
      let scalar = source.unicodeScalars[end]
      let size = scalar.utf8.count
      // Match native text layout, not just JSONL's LF boundary. CRLF is one
      // break; CR, NEL and Unicode paragraph/line separators also consume rows.
      let isLineBreak =
        newlines.contains(scalar)
        && !(previousWasCR && scalar == "\n")
      if bytes + size > maximumBytes || (isLineBreak && lines >= maximumLines) { break }
      bytes += size
      if isLineBreak { lines += 1 }
      previousWasCR = scalar == "\r"
      end = source.unicodeScalars.index(after: end)
    }
    text = String(source[..<end])
    isTruncated = end != source.endIndex
    lineCount = lines
  }

  /// Literal, non-overlapping UTF-16 ranges for NSTextView; never interpret a regex.
  func matches(for query: String) -> [NSRange] {
    guard !query.isEmpty else { return [] }
    let source = text as NSString
    var search = NSRange(location: 0, length: source.length)
    var result: [NSRange] = []
    while search.length > 0 && result.count < Self.maximumMatches {
      let match = source.range(of: query, options: [.caseInsensitive], range: search)
      guard match.location != NSNotFound && match.length > 0 else { break }
      result.append(match)
      let end = NSMaxRange(match)
      search = NSRange(location: end, length: source.length - end)
    }
    return result
  }
}

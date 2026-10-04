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
    maximumLines: Int = Self.maximumLines, fromEnd: Bool = false
  ) {
    precondition(maximumBytes > 0 && maximumLines > 0)
    let scalars = source.unicodeScalars
    var boundary = fromEnd ? scalars.endIndex : scalars.startIndex
    let terminal = fromEnd ? scalars.startIndex : scalars.endIndex
    var bytes = 0
    var lines = 1
    var previousWasPairStart = false
    let newlines = CharacterSet.newlines
    while boundary != terminal {
      let index = fromEnd ? scalars.index(before: boundary) : boundary
      let scalar = scalars[index]
      let size = scalar.utf8.count
      // CRLF is one break in either direction; all native Unicode separators count.
      let isLineBreak =
        newlines.contains(scalar)
        && !(previousWasPairStart && scalar == (fromEnd ? "\r" : "\n"))
      if bytes + size > maximumBytes || (isLineBreak && lines >= maximumLines) { break }
      bytes += size
      if isLineBreak { lines += 1 }
      previousWasPairStart = scalar == (fromEnd ? "\n" : "\r")
      boundary = fromEnd ? index : scalars.index(after: index)
    }
    text = fromEnd ? String(source[boundary...]) : String(source[..<boundary])
    isTruncated = boundary != terminal
    lineCount = lines
  }

  /// Literal, non-overlapping UTF-16 ranges for NSTextView; never interpret a regex.
  func matches(for query: String) -> [NSRange] {
    search(for: query).ranges
  }

  func search(for query: String, options: ToolOutputSearchOptions = .init()) -> ToolOutputMatches {
    guard !query.isEmpty else { return ToolOutputMatches(ranges: [], hasMore: false) }
    let source = text as NSString
    var search = NSRange(location: 0, length: source.length)
    var result: [NSRange] = []
    while search.length > 0 {
      let match = source.range(
        of: query, options: options.caseSensitive ? [] : [.caseInsensitive], range: search)
      guard match.location != NSNotFound && match.length > 0 else { break }
      let end = NSMaxRange(match)
      search = NSRange(location: end, length: source.length - end)
      if options.wholeWord && !isWholeWord(match, in: source) { continue }
      if result.count == Self.maximumMatches {
        return ToolOutputMatches(ranges: result, hasMore: true)
      }
      result.append(match)
    }
    return ToolOutputMatches(ranges: result, hasMore: false)
  }

  private static let wordCharacters = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(
    CharacterSet(charactersIn: "_"))

  private func isWholeWord(_ match: NSRange, in source: NSString) -> Bool {
    // Inspect adjacent UTF-16 units directly: repeatedly converting offsets to
    // Swift String indices can make dense Unicode searches quadratic.
    if match.location > 0, let scalar = scalar(at: match.location - 1, in: source),
      Self.wordCharacters.contains(scalar)
    {
      return false
    }
    let end = NSMaxRange(match)
    if end < source.length, let scalar = scalar(at: end, in: source),
      Self.wordCharacters.contains(scalar)
    {
      return false
    }
    return true
  }

  private func scalar(at index: Int, in source: NSString) -> Unicode.Scalar? {
    let unit = UInt32(source.character(at: index))
    var lead = unit
    var trail: UInt32?
    if (0xD800...0xDBFF).contains(unit), index + 1 < source.length {
      trail = UInt32(source.character(at: index + 1))
    } else if (0xDC00...0xDFFF).contains(unit), index > 0 {
      lead = UInt32(source.character(at: index - 1))
      trail = unit
    }
    if (0xD800...0xDBFF).contains(lead), let trail, (0xDC00...0xDFFF).contains(trail) {
      return Unicode.Scalar(0x10000 + ((lead - 0xD800) << 10) + trail - 0xDC00)
    }
    return Unicode.Scalar(unit)
  }
}

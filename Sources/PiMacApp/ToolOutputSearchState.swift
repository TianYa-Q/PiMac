import Foundation

struct ToolOutputSearchOptions: Equatable {
  var caseSensitive = false
  var wholeWord = false
}

struct ToolOutputMatches: Equatable {
  let ranges: [NSRange]
  let hasMore: Bool
}

/// Scan only when preview/query/options change, never when navigating or toggling wrapping.
struct ToolOutputSearchState {
  private(set) var preview: ToolOutputPresentation
  private(set) var query = ""
  private(set) var fromEnd = false
  private(set) var options = ToolOutputSearchOptions()
  private(set) var matches = ToolOutputMatches(ranges: [], hasMore: false)
  private(set) var matchIndex = 0

  init(text: String) {
    preview = ToolOutputPresentation(text: text)
  }

  var selectedRange: NSRange? {
    matches.ranges.isEmpty ? nil : matches.ranges[matchIndex]
  }

  var matchLabel: String {
    guard !query.isEmpty else { return "" }
    guard !matches.ranges.isEmpty else { return "无匹配" }
    return "\(matchIndex + 1)/\(matches.ranges.count)\(matches.hasMore ? "+" : "")"
  }

  mutating func updateText(_ text: String) {
    let next = ToolOutputPresentation(text: text, fromEnd: fromEnd)
    guard next != preview else { return }
    let selection = selectedRange
    preview = next
    matches = preview.search(for: query, options: options)
    // Head appends retain the current result. Tail windows shift their coordinate
    // origin, so an identical relative range can refer to a different match.
    matchIndex = fromEnd ? 0 : selection.flatMap { matches.ranges.firstIndex(of: $0) } ?? 0
  }

  mutating func setFromEnd(_ fromEnd: Bool, text: String) {
    guard self.fromEnd != fromEnd else { return }
    self.fromEnd = fromEnd
    preview = ToolOutputPresentation(text: text, fromEnd: fromEnd)
    rescan()
  }

  mutating func setQuery(_ query: String) {
    guard self.query != query else { return }
    self.query = query
    rescan()
  }

  mutating func setOptions(_ options: ToolOutputSearchOptions) {
    guard self.options != options else { return }
    self.options = options
    rescan()
  }

  mutating func move(by offset: Int) {
    let count = matches.ranges.count
    guard count > 0 else { return }
    // Reduce first so arbitrary offsets cannot overflow the index arithmetic.
    matchIndex = (matchIndex + offset % count + count) % count
  }

  private mutating func rescan() {
    matches = preview.search(for: query, options: options)
    matchIndex = 0
  }
}

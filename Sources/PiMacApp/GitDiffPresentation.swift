import Foundation

/// Bounded line model shared by diff rendering, statistics and search.
struct GitDiffPresentation: Equatable {
  enum Kind: Equatable { case context, addition, deletion, header, hunk }
  enum Scope: String, CaseIterable, Identifiable {
    case all = "全部"
    case changes = "仅变更"
    var id: String { rawValue }
  }
  struct Line: Identifiable, Equatable {
    let id: Int
    let text: String
    let kind: Kind
  }
  let lines: [Line]
  let truncated: Bool
  let additions: Int
  let deletions: Int

  init(_ text: String, maxLines: Int = 10_000) {
    precondition(maxLines > 0)
    var lines: [Line] = []
    var additions = 0
    var deletions = 0
    var truncated = false
    var inHunk = false
    // Do not split the entire string: a byte-bounded diff can still contain millions of LFs.
    var remainder = text[...]
    while !remainder.isEmpty {
      guard lines.count < maxLines else {
        truncated = true
        break
      }
      let end = remainder.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) ?? remainder.endIndex
      var raw = remainder[..<end]
      if raw.last == "\r" { raw = raw.dropLast() }
      let value = String(raw)
      let kind: Kind
      if value.hasPrefix("diff ") {
        inHunk = false
        kind = .header
      } else if !inHunk
        && (value.hasPrefix("index ")
          || value.hasPrefix("--- ") || value.hasPrefix("+++ "))
      {
        kind = .header
      } else if value.hasPrefix("@@") {
        inHunk = true
        kind = .hunk
      } else if value.hasPrefix("+") {
        kind = .addition
        additions += 1
      } else if value.hasPrefix("-") {
        kind = .deletion
        deletions += 1
      } else {
        kind = .context
      }
      lines.append(Line(id: lines.count + 1, text: value, kind: kind))
      remainder =
        end == remainder.endIndex ? remainder[end...] : remainder[remainder.index(after: end)...]
    }
    self.lines = lines
    self.truncated = truncated
    self.additions = additions
    self.deletions = deletions
  }

  func filtered(query: String, scope: Scope) -> [Line] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return lines.filter { line in
      (scope == .all || line.kind == .addition || line.kind == .deletion)
        && (term.isEmpty || line.text.localizedStandardContains(term))
    }
  }
}

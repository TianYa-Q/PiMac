import Foundation
import SwiftUI

/// Lightweight GitHub-flavoured Markdown block parser used by chat messages.
/// Foundation's `AttributedString(markdown:)` only renders inline syntax, so block
/// constructs (tables, lists, headings, quotes and code fences) are handled here.
struct MarkdownDocument: Equatable {
  var blocks: [MarkdownBlock]

  init(_ source: String) {
    blocks = MarkdownParser.parse(source)
  }
}

enum MarkdownBlock: Equatable {
  case paragraph(String)
  case heading(level: Int, text: String)
  case code(language: String?, text: String)
  case quote(String)
  case list(ordered: Bool, start: Int, items: [String])
  case table(headers: [String], rows: [[String]], alignments: [MarkdownAlignment])
  case divider
}

enum MarkdownAlignment: Equatable {
  case leading
  case center
  case trailing
}

enum MarkdownParser {
  static func parse(_ source: String) -> [MarkdownBlock] {
    let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.components(separatedBy: "\n")
    var blocks: [MarkdownBlock] = []
    var index = 0

    while index < lines.count {
      let line = lines[index]
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        index += 1
        continue
      }

      if let fence = fenceStart(line) {
        var code: [String] = []
        index += 1
        while index < lines.count && !isClosingFence(lines[index], marker: fence.marker) {
          code.append(lines[index])
          index += 1
        }
        if index < lines.count { index += 1 }
        blocks.append(.code(language: fence.language, text: code.joined(separator: "\n")))
        continue
      }

      if line.hasPrefix("    ") || line.hasPrefix("\t") {
        var code: [String] = []
        while index < lines.count {
          let current = lines[index]
          if current.hasPrefix("    ") {
            code.append(String(current.dropFirst(4)))
          } else if current.hasPrefix("\t") {
            code.append(String(current.dropFirst()))
          } else if current.isEmpty {
            code.append("")
          } else {
            break
          }
          index += 1
        }
        while code.last == "" { code.removeLast() }
        blocks.append(.code(language: nil, text: code.joined(separator: "\n")))
        continue
      }

      if let heading = atxHeading(line) {
        blocks.append(.heading(level: heading.level, text: heading.text))
        index += 1
        continue
      }

      if index + 1 < lines.count, let level = setextLevel(lines[index + 1]), !line.isEmpty {
        blocks.append(.heading(level: level, text: line.trimmingCharacters(in: .whitespaces)))
        index += 2
        continue
      }

      if isDivider(line) {
        blocks.append(.divider)
        index += 1
        continue
      }

      if index + 1 < lines.count,
        let alignments = tableDelimiter(lines[index + 1])
      {
        let headers = tableCells(line)
        if !headers.isEmpty {
          var rows: [[String]] = []
          index += 2
          while index < lines.count,
            !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
            lines[index].contains("|")
          {
            rows.append(tableCells(lines[index]))
            index += 1
          }
          let columnCount = max(headers.count, alignments.count, rows.map(\.count).max() ?? 0)
          blocks.append(
            .table(
              headers: padded(headers, to: columnCount),
              rows: rows.map { padded($0, to: columnCount) },
              alignments: padded(alignments, to: columnCount, with: .leading)
            ))
          continue
        }
      }

      // Models occasionally omit the required `--- | ---` delimiter row. When
      // several equally shaped pipe-separated lines are present, render them as
      // a table instead of exposing the Markdown punctuation to the user.
      if let inferred = inferredTable(lines, from: index) {
        blocks.append(
          .table(
            headers: inferred.headers,
            rows: inferred.rows,
            alignments: Array(repeating: .leading, count: inferred.headers.count)
          ))
        index = inferred.endIndex
        continue
      }

      if quoteText(line) != nil {
        var quoted: [String] = []
        while index < lines.count, let text = quoteText(lines[index]) {
          quoted.append(text)
          index += 1
        }
        blocks.append(.quote(quoted.joined(separator: "\n")))
        continue
      }

      if let firstItem = listItem(line) {
        var items = [firstItem.text]
        let ordered = firstItem.ordered
        let start = firstItem.number ?? 1
        index += 1
        while index < lines.count {
          if let item = listItem(lines[index]), item.ordered == ordered {
            items.append(item.text)
            index += 1
          } else if !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
            lines[index].hasPrefix("  ")
          {
            items[items.count - 1] += "\n" + lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
          } else {
            break
          }
        }
        blocks.append(.list(ordered: ordered, start: start, items: items))
        continue
      }

      var paragraph = [line]
      index += 1
      while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
        let next = lines[index]
        if fenceStart(next) != nil || atxHeading(next) != nil || isDivider(next)
          || quoteText(next) != nil || listItem(next) != nil
          || (index + 1 < lines.count && tableDelimiter(lines[index + 1]) != nil)
          || inferredTable(lines, from: index) != nil
        {
          break
        }
        paragraph.append(next)
        index += 1
      }
      blocks.append(.paragraph(paragraph.joined(separator: "\n")))
    }
    return blocks
  }

  private static func fenceStart(_ line: String) -> (marker: Character, language: String?)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
    let count = trimmed.prefix(while: { $0 == marker }).count
    guard count >= 3 else { return nil }
    let info = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
    return (marker, info.isEmpty ? nil : info)
  }

  private static func isClosingFence(_ line: String, marker: Character) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.prefix(while: { $0 == marker }).count >= 3
  }

  private static func atxHeading(_ line: String) -> (level: Int, text: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let count = trimmed.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(count), trimmed.dropFirst(count).first == " " else { return nil }
    var text = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
    while text.last == "#" { text.removeLast() }
    return (count, text.trimmingCharacters(in: .whitespaces))
  }

  private static func setextLevel(_ line: String) -> Int? {
    let text = line.trimmingCharacters(in: .whitespaces)
    guard text.count >= 3, let first = text.first,
      first == "=" || first == "-", text.allSatisfy({ $0 == first })
    else { return nil }
    return first == "=" ? 1 : 2
  }

  private static func isDivider(_ line: String) -> Bool {
    let text = line.filter { !$0.isWhitespace }
    guard text.count >= 3, let first = text.first, first == "-" || first == "*" || first == "_"
    else { return false }
    return text.allSatisfy { $0 == first }
  }

  private static func quoteText(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.first == ">" else { return nil }
    return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
  }

  private static func listItem(_ line: String) -> (ordered: Bool, number: Int?, text: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
      return (false, nil, String(trimmed.dropFirst(2)))
    }
    guard let punctuation = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) else {
      return nil
    }
    let prefix = trimmed[..<punctuation]
    guard let number = Int(prefix), trimmed.index(after: punctuation) < trimmed.endIndex,
      trimmed[trimmed.index(after: punctuation)] == " "
    else { return nil }
    let textStart = trimmed.index(punctuation, offsetBy: 2)
    return (true, number, String(trimmed[textStart...]))
  }

  private static func inferredTable(
    _ lines: [String],
    from startIndex: Int
  ) -> (headers: [String], rows: [[String]], endIndex: Int)? {
    guard startIndex + 1 < lines.count, lines[startIndex].contains("|") else { return nil }
    let headers = tableCells(lines[startIndex])
    guard headers.count >= 2 else { return nil }

    var rows: [[String]] = []
    var index = startIndex + 1
    while index < lines.count,
      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
      lines[index].contains("|")
    {
      let cells = tableCells(lines[index])
      guard cells.count == headers.count else { break }
      rows.append(cells)
      index += 1
    }
    guard !rows.isEmpty else { return nil }
    return (headers, rows, index)
  }

  private static func tableDelimiter(_ line: String) -> [MarkdownAlignment]? {
    let cells = tableCells(line)
    guard !cells.isEmpty else { return nil }
    var result: [MarkdownAlignment] = []
    for cell in cells {
      let value = cell.replacingOccurrences(of: " ", with: "")
      let core = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
      guard core.count >= 3, core.allSatisfy({ $0 == "-" }) else { return nil }
      if value.hasPrefix(":"), value.hasSuffix(":") {
        result.append(.center)
      } else if value.hasSuffix(":") {
        result.append(.trailing)
      } else {
        result.append(.leading)
      }
    }
    return result
  }

  private static func tableCells(_ line: String) -> [String] {
    var text = line.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("|") { text.removeFirst() }
    if text.hasSuffix("|") { text.removeLast() }
    // A backslash-escaped pipe is not a column boundary.
    var cells: [String] = []
    var current = ""
    var escaped = false
    for character in text {
      if character == "|" && !escaped {
        cells.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
      } else {
        current.append(character)
      }
      escaped = character == "\\" && !escaped
      if character != "\\" { escaped = false }
    }
    cells.append(current.trimmingCharacters(in: .whitespaces))
    return cells
  }

  private static func padded<T>(_ values: [T], to count: Int, with defaultValue: T) -> [T] {
    values + Array(repeating: defaultValue, count: max(0, count - values.count))
  }

  private static func padded(_ values: [String], to count: Int) -> [String] {
    padded(values, to: count, with: "")
  }
}

private final class MarkdownDocumentBox {
  let value: MarkdownDocument
  init(_ value: MarkdownDocument) { self.value = value }
}

private enum MarkdownDocumentCache {
  static let cache: NSCache<NSString, MarkdownDocumentBox> = {
    let cache = NSCache<NSString, MarkdownDocumentBox>()
    cache.countLimit = 256
    cache.totalCostLimit = 8 * 1_024 * 1_024
    return cache
  }()

  static func document(for source: String) -> MarkdownDocument {
    let key = source as NSString
    if let cached = cache.object(forKey: key) { return cached.value }
    let document = MarkdownDocument(source)
    cache.setObject(MarkdownDocumentBox(document), forKey: key, cost: source.utf8.count)
    return document
  }
}

struct MarkdownView: View {
  let document: MarkdownDocument

  init(_ source: String) {
    document = MarkdownDocumentCache.document(for: source)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
        switch section {
        case .text(let blocks):
          combinedText(blocks)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        case .table(let headers, let rows, let alignments):
          MarkdownTableView(headers: headers, rows: rows, alignments: alignments)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Keep adjacent non-table blocks in one Text so selection can cross paragraphs.
  /// Tables need real cell layout and therefore form their own sections.
  private var sections: [MarkdownSection] {
    var result: [MarkdownSection] = []
    var textBlocks: [MarkdownBlock] = []

    func flushText() {
      guard !textBlocks.isEmpty else { return }
      result.append(.text(textBlocks))
      textBlocks.removeAll()
    }

    for block in document.blocks {
      if case .table(let headers, let rows, let alignments) = block {
        flushText()
        result.append(.table(headers: headers, rows: rows, alignments: alignments))
      } else {
        textBlocks.append(block)
      }
    }
    flushText()
    return result
  }

  private func combinedText(_ blocks: [MarkdownBlock]) -> Text {
    blocks.enumerated().reduce(Text("")) { result, element in
      let separator = element.offset == 0 ? Text("") : Text("\n\n")
      return result + separator + blockText(element.element)
    }
  }

  private func blockText(_ block: MarkdownBlock) -> Text {
    switch block {
    case .paragraph(let text):
      return inlineText(text)
    case .heading(let level, let text):
      return inlineText(text).font(headingFont(level))
    case .code(let language, let text):
      let label =
        language.map {
          Text("\($0)\n").font(.caption2).foregroundColor(.secondary)
        } ?? Text("")
      return label
        + Text(text.isEmpty ? " " : text)
        .font(.system(.body, design: .monospaced))
    case .quote(let text):
      let quoted = text.replacingOccurrences(of: "\n", with: "\n▎ ")
      return Text("▎ ").foregroundColor(.accentColor)
        + inlineText(quoted).foregroundColor(.secondary)
    case .list(let ordered, let start, let items):
      return items.enumerated().reduce(Text("")) { result, element in
        let separator = element.offset == 0 ? Text("") : Text("\n")
        let markerText = listMarker(element.element)
        let marker = ordered ? "\(start + element.offset). " : "\(markerText) "
        return result + separator + Text(marker).foregroundColor(.secondary)
          + inlineText(listText(element.element))
      }
    case .table:
      return Text("")
    case .divider:
      return Text("────────────────────────").foregroundColor(.secondary)
    }
  }

  private func inlineText(_ source: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace)
    let attributed =
      (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    return Text(attributed)
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .title.bold()
    case 2: .title2.bold()
    case 3: .title3.bold()
    default: .headline
    }
  }

  private func listMarker(_ text: String) -> String {
    if text.hasPrefix("[ ] ") { return "☐" }
    if text.lowercased().hasPrefix("[x] ") { return "☑" }
    return "•"
  }

  private func listText(_ text: String) -> String {
    if text.hasPrefix("[ ] ") || text.lowercased().hasPrefix("[x] ") {
      return String(text.dropFirst(4))
    }
    return text
  }
}

private enum MarkdownSection {
  case text([MarkdownBlock])
  case table(headers: [String], rows: [[String]], alignments: [MarkdownAlignment])
}

private struct MarkdownTableView: View {
  let headers: [String]
  let rows: [[String]]
  let alignments: [MarkdownAlignment]

  var body: some View {
    VStack(spacing: 0) {
      row(headers, isHeader: true)
      Divider()
      ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
        row(cells, isHeader: false)
        if index < rows.count - 1 { Divider() }
      }
    }
    .background(Color.primary.opacity(0.035))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
    }
    .textSelection(.enabled)
  }

  private func row(_ cells: [String], isHeader: Bool) -> some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(cells.indices, id: \.self) { index in
        if index > 0 { Divider() }
        inlineText(cells[index])
          .font(isHeader ? .callout.bold() : .callout)
          .frame(maxWidth: .infinity, alignment: alignment(at: index))
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
      }
    }
    .background(isHeader ? Color.primary.opacity(0.055) : Color.clear)
    .fixedSize(horizontal: false, vertical: true)
  }

  private func inlineText(_ source: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace)
    let attributed =
      (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    return Text(attributed)
  }

  private func alignment(at index: Int) -> Alignment {
    guard alignments.indices.contains(index) else { return .leading }
    return switch alignments[index] {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }
}

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
         let alignments = tableDelimiter(lines[index + 1]) {
        let headers = tableCells(line)
        if !headers.isEmpty {
          var rows: [[String]] = []
          index += 2
          while index < lines.count,
                !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                lines[index].contains("|") {
            rows.append(tableCells(lines[index]))
            index += 1
          }
          let columnCount = max(headers.count, alignments.count, rows.map(\.count).max() ?? 0)
          blocks.append(.table(
            headers: padded(headers, to: columnCount),
            rows: rows.map { padded($0, to: columnCount) },
            alignments: padded(alignments, to: columnCount, with: .leading)
          ))
          continue
        }
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
                    lines[index].hasPrefix("  ") {
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
          || (index + 1 < lines.count && tableDelimiter(lines[index + 1]) != nil) {
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
          (first == "=" || first == "-"), text.allSatisfy({ $0 == first }) else { return nil }
    return first == "=" ? 1 : 2
  }

  private static func isDivider(_ line: String) -> Bool {
    let text = line.filter { !$0.isWhitespace }
    guard text.count >= 3, let first = text.first, first == "-" || first == "*" || first == "_" else { return false }
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
    guard let punctuation = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
    let prefix = trimmed[..<punctuation]
    guard let number = Int(prefix), trimmed.index(after: punctuation) < trimmed.endIndex,
          trimmed[trimmed.index(after: punctuation)] == " " else { return nil }
    let textStart = trimmed.index(punctuation, offsetBy: 2)
    return (true, number, String(trimmed[textStart...]))
  }

  private static func tableDelimiter(_ line: String) -> [MarkdownAlignment]? {
    let cells = tableCells(line)
    guard !cells.isEmpty else { return nil }
    var result: [MarkdownAlignment] = []
    for cell in cells {
      let value = cell.replacingOccurrences(of: " ", with: "")
      let core = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
      guard core.count >= 3, core.allSatisfy({ $0 == "-" }) else { return nil }
      if value.hasPrefix(":"), value.hasSuffix(":") { result.append(.center) }
      else if value.hasSuffix(":") { result.append(.trailing) }
      else { result.append(.leading) }
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

struct MarkdownView: View {
  let document: MarkdownDocument

  init(_ source: String) {
    document = MarkdownDocument(source)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .textSelection(.enabled)
  }

  @ViewBuilder
  private func blockView(_ block: MarkdownBlock) -> some View {
    switch block {
    case .paragraph(let text):
      inlineText(text)
        .fixedSize(horizontal: false, vertical: true)
    case .heading(let level, let text):
      inlineText(text)
        .font(headingFont(level))
        .padding(.top, level <= 2 ? 4 : 1)
    case .code(let language, let text):
      VStack(alignment: .leading, spacing: 4) {
        if let language { Text(language).font(.caption2).foregroundStyle(.secondary) }
        ScrollView(.horizontal) {
          Text(text.isEmpty ? " " : text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(9)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.14)))
    case .quote(let text):
      HStack(alignment: .top, spacing: 9) {
        Rectangle().fill(Color.accentColor.opacity(0.55)).frame(width: 3)
        MarkdownView(text).foregroundStyle(.secondary)
      }
    case .list(let ordered, let start, let items):
      VStack(alignment: .leading, spacing: 5) {
        ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
          HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(ordered ? "\(start + offset)." : listMarker(item))
              .foregroundStyle(.secondary)
              .frame(minWidth: 16, alignment: .trailing)
            inlineText(listText(item)).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(.leading, 4)
    case .table(let headers, let rows, let alignments):
      tableView(headers: headers, rows: rows, alignments: alignments)
    case .divider:
      Divider().padding(.vertical, 2)
    }
  }

  private func inlineText(_ source: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    let attributed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
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

  private func alignment(_ value: MarkdownAlignment) -> Alignment {
    switch value {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  private func tableView(headers: [String], rows: [[String]], alignments: [MarkdownAlignment]) -> some View {
    ScrollView(.horizontal) {
      Grid(horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(headers.indices, id: \.self) { column in
            inlineText(headers[column])
              .fontWeight(.semibold)
              .padding(.horizontal, 9).padding(.vertical, 7)
              .frame(minWidth: 90, maxWidth: 300, alignment: alignment(alignments[column]))
          }
        }
        .background(Color.secondary.opacity(0.12))
        ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
          Divider().gridCellUnsizedAxes(.horizontal)
          GridRow {
            ForEach(row.indices, id: \.self) { column in
              inlineText(row[column])
                .padding(.horizontal, 9).padding(.vertical, 7)
                .frame(minWidth: 90, maxWidth: 300, alignment: alignment(alignments[column]))
            }
          }
          .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.035))
        }
      }
    }
    .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.18)))
  }
}

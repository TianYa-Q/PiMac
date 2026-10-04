import AppKit
import SwiftUI

/// Presentation only: preserve the original input/output for selection and copying.
struct ReadToolSummary: Equatable {
  let path: String
  let range: String?

  init(input: String) {
    if let match = input.range(of: #":\d+(?:-\d+)?$"#, options: .regularExpression) {
      path = String(input[..<match.lowerBound])
      range = String(input[input.index(after: match.lowerBound)...])
    } else {
      path = input
      range = nil
    }
  }

  var fileName: String { (path as NSString).lastPathComponent }
  var rangeLabel: String? { range.map { "第 \($0) 行" } }
}

struct ReadToolInputView: View {
  let input: String
  private var summary: ReadToolSummary { ReadToolSummary(input: input) }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(summary.fileName)
          .font(.system(.caption, design: .monospaced).weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
        if let range = summary.rangeLabel {
          Text(range)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize()
        }
      }
      if summary.path != summary.fileName {
        Text(summary.path)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .help(input)
  }
}

struct ToolDetailView: View {
  let title: String
  let text: String
  @State private var isSearching = false
  @State private var query = ""
  @State private var matchIndex = 0
  @State private var wrapsLines = false
  @FocusState private var searchFocused: Bool

  var body: some View {
    let preview = ToolOutputPresentation(text: text)
    let matches = preview.matches(for: query)
    let selected = matches.isEmpty ? nil : matches[matchIndex % matches.count]
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Text(title).font(.caption2.weight(.semibold))
        Text("\(preview.lineCount) 行\(preview.isTruncated ? " · 预览" : "")")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Spacer()
        Button {
          isSearching.toggle()
          searchFocused = isSearching
          if !isSearching { query = "" }
        } label: {
          Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.plain)
        .help("搜索预览")
        .accessibilityLabel("搜索\(title)预览")
        Button {
          wrapsLines.toggle()
        } label: {
          Image(systemName: wrapsLines ? "arrow.uturn.down" : "arrow.right")
        }
        .buttonStyle(.plain)
        .help(wrapsLines ? "关闭自动换行" : "自动换行")
        .accessibilityLabel("自动换行")
        .accessibilityValue(wrapsLines ? "开启" : "关闭")
        Button {
          exportOutput()
        } label: {
          Image(systemName: "square.and.arrow.down")
        }
        .buttonStyle(.plain)
        .help("导出完整\(title)")
        .accessibilityLabel("导出完整\(title)")
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.plain)
        .help("复制\(title)")
        .accessibilityLabel("复制\(title)")
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      Divider().opacity(0.5)
      if isSearching {
        HStack(spacing: 6) {
          TextField("搜索预览（不区分大小写）", text: $query)
            .textFieldStyle(.roundedBorder)
            .focused($searchFocused)
            .onChange(of: query) { _, _ in matchIndex = 0 }
            .onSubmit { moveMatch(by: 1, count: matches.count) }
            .onExitCommand {
              isSearching = false
              query = ""
              searchFocused = false
            }
          Text(
            query.isEmpty
              ? ""
              : matches.isEmpty
                ? "无匹配"
                : "\(matchIndex % matches.count + 1)/\(matches.count)\(matches.count == ToolOutputPresentation.maximumMatches ? "+" : "")"
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          Button {
            moveMatch(by: -1, count: matches.count)
          } label: {
            Image(systemName: "chevron.up")
          }
          .help("上一个匹配")
          .accessibilityLabel("上一个匹配")
          .disabled(matches.isEmpty)
          Button {
            moveMatch(by: 1, count: matches.count)
          } label: {
            Image(systemName: "chevron.down")
          }
          .help("下一个匹配")
          .accessibilityLabel("下一个匹配")
          .disabled(matches.isEmpty)
        }
        .padding(6)
      }
      ToolOutputView(text: preview.text, searchSelection: selected, wrapsLines: wrapsLines)
      if preview.isTruncated {
        Text("仅显示前 \(ToolOutputPresentation.maximumLines) 行／128 KiB 以内内容；搜索仅覆盖预览，复制与导出保留完整内容。")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .padding(9)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.46))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
    }
  }

  private func moveMatch(by offset: Int, count: Int) {
    guard count > 0 else { return }
    matchIndex = (matchIndex % count + offset + count) % count
  }

  private func exportOutput() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "tool-output.txt"
    panel.canCreateDirectories = true
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do {
        try text.write(to: url, atomically: true, encoding: .utf8)
      } catch {
        NSAlert(error: error).runModal()
      }
    }
  }
}

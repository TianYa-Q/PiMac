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
  var isExpanded = false
  @State private var showsInspector = false
  @State private var followsTail = false
  @State private var isSearching = false
  @State private var search = ToolOutputSearchState(text: "")
  @State private var wrapsLines = false
  @FocusState private var searchFocused: Bool

  var body: some View {
    let preview = search.preview
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Text(title).font(.caption2.weight(.semibold))
        Text(
          "\(preview.lineCount) 行\(preview.isTruncated ? (search.fromEnd ? " · 尾部预览" : " · 开头预览") : "")"
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
        Spacer()
        if !isExpanded {
          Button {
            showsInspector = true
          } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
          }
          .buttonStyle(.plain)
          .help("放大阅读\(title)")
          .accessibilityLabel("放大阅读\(title)")
        }
        if search.fromEnd {
          Button {
            followsTail.toggle()
          } label: {
            Image(systemName: followsTail ? "pause.circle" : "play.circle")
          }
          .buttonStyle(.plain)
          .help(followsTail ? "暂停尾部跟随" : "跟随最新输出（搜索时暂缓）")
          .accessibilityLabel("跟随最新输出")
          .accessibilityValue(followsTail ? "开启" : "关闭")
        }
        Button {
          isSearching.toggle()
          searchFocused = isSearching
          if !isSearching { search.setQuery("") }
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
          search.setFromEnd(!search.fromEnd, text: text)
        } label: {
          Image(systemName: search.fromEnd ? "arrow.down.to.line" : "arrow.up.to.line")
        }
        .buttonStyle(.plain)
        .help(search.fromEnd ? "切换到开头预览" : "切换到尾部预览（查看最新输出）")
        .accessibilityLabel("尾部预览")
        .accessibilityValue(search.fromEnd ? "开启" : "关闭")
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
          TextField(
            "搜索预览（字面文本）",
            text: Binding(get: { search.query }, set: { search.setQuery($0) })
          )
          .textFieldStyle(.roundedBorder)
          .focused($searchFocused)
          .onSubmit { search.move(by: 1) }
          .onExitCommand {
            isSearching = false
            search.setQuery("")
            searchFocused = false
          }
          searchOption("Aa", keyPath: \.caseSensitive, help: "区分大小写")
          searchOption("ab", keyPath: \.wholeWord, help: "整词匹配（字母、数字、下划线为词内字符）")
          Text(search.matchLabel)
            .font(.caption2)
            .foregroundStyle(.secondary)
          Button {
            search.move(by: -1)
          } label: {
            Image(systemName: "chevron.up")
          }
          .help("上一个匹配")
          .accessibilityLabel("上一个匹配")
          .disabled(search.matches.ranges.isEmpty)
          Button {
            search.move(by: 1)
          } label: {
            Image(systemName: "chevron.down")
          }
          .help("下一个匹配")
          .accessibilityLabel("下一个匹配")
          .disabled(search.matches.ranges.isEmpty)
        }
        .padding(6)
      }
      ToolOutputView(
        text: preview.text, searchSelection: search.selectedRange, wrapsLines: wrapsLines,
        searchMatches: search.matches.ranges, followsTail: followsTail && search.fromEnd,
        maximumHeight: isExpanded ? 600 : 300)
      if preview.isTruncated {
        Text(
          "仅显示\(search.fromEnd ? "尾部" : "开头") \(ToolOutputPresentation.maximumLines) 行／128 KiB 以内内容；搜索仅覆盖预览，复制与导出保留完整内容。"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(9)
      }
    }
    .sheet(isPresented: $showsInspector) {
      ToolOutputInspector(title: title, text: text)
    }
    .onChange(of: text, initial: true) { _, next in search.updateText(next) }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.46))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
    }
  }

  private func searchOption(
    _ label: String, keyPath: WritableKeyPath<ToolOutputSearchOptions, Bool>, help: String
  ) -> some View {
    Button {
      var options = search.options
      options[keyPath: keyPath].toggle()
      search.setOptions(options)
    } label: {
      Text(label).font(.system(.caption, design: .monospaced).weight(.semibold))
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(
          search.options[keyPath: keyPath] ? Color.accentColor.opacity(0.18) : Color.clear,
          in: RoundedRectangle(cornerRadius: 4))
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
    .accessibilityValue(search.options[keyPath: keyPath] ? "开启" : "关闭")
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

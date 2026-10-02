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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Text(title).font(.caption2.weight(.semibold))
        Text("\(text.components(separatedBy: "\n").count) 行")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Spacer()
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
      ToolOutputView(text: text)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.46))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
    }
  }
}

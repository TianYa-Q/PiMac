import SwiftUI

/// Reuses bounded parsing and native text layout instead of rendering the whole retained transcript.
struct ToolOutputInspector: View {
  let title: String
  let text: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(title, systemImage: "doc.text.magnifyingglass").font(.headline)
        Spacer()
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      ToolDetailView(title: title, text: text, isExpanded: true)
      Spacer(minLength: 0)
    }
    .padding(20)
    .frame(width: 900, height: 760)
  }
}

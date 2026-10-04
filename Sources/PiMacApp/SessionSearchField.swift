import SwiftUI

/// Shared search affordances kept separate from the sidebar's session rendering.
struct SessionSearchField: View {
  @Binding var text: String
  var focused: FocusState<Bool>.Binding
  let onClose: () -> Void
  let onSubmit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索聊天记录", text: $text)
          .textFieldStyle(.plain)
          .focused(focused)
          .accessibilityLabel("搜索聊天记录")
          .onExitCommand(perform: onClose)
          .onSubmit(onSubmit)
        if !text.isEmpty {
          Button {
            text = ""
            focused.wrappedValue = true
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help("清除搜索")
          .accessibilityLabel("清除搜索")
        }
      }
      .font(.callout)
      .padding(8)
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
      HStack(spacing: 6) {
        scopeButton("标题", prefix: "title:", symbol: "textformat")
        scopeButton("正文", prefix: "text:", symbol: "text.alignleft")
        Spacer(minLength: 0)
      }
      Text("多个词 · \"精确短语\" · -排除 · title:标题 · text:正文")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func scopeButton(_ label: String, prefix: String, symbol: String) -> some View {
    Button {
      if !text.isEmpty && text.last?.isWhitespace != true { text += " " }
      text += prefix
      focused.wrappedValue = true
    } label: {
      Label(label, systemImage: symbol)
        .font(.caption2)
    }
    .buttonStyle(.bordered)
    .controlSize(.mini)
    .help("插入 \(prefix)，后接关键词或带引号的短语")
    .accessibilityLabel("添加\(label)搜索条件")
  }
}

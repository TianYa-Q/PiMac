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
      Text("多个关键词 · \"精确短语\" · -排除词")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}

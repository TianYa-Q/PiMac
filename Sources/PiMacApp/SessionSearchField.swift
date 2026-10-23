import SwiftUI

/// Shared search affordances kept separate from the sidebar's session rendering.
struct SessionSearchField: View {
  @Binding var text: String
  var focused: FocusState<Bool>.Binding
  let onClose: () -> Void
  let onSubmit: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("搜索聊天正文", text: $text)
        .textFieldStyle(.plain)
        .focused(focused)
        .accessibilityLabel("搜索聊天正文")
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
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(.primary.opacity(focused.wrappedValue ? 0.18 : 0.06), lineWidth: 1)
    }
    .help("T3 原生正文搜索：输入 2–200 个字符，按原文匹配。取 Server 全局前 50 个命中会话，再按当前列表筛选。")
  }
}

import SwiftUI

/// Selecting and submitting are separate actions: narrowing a search must never authorize
/// the only remaining permission choice. Native List supplies arrow-key navigation.
struct ExtensionOptionPicker: View {
  let options: [String]
  let answer: (String) -> Void
  let cancel: () -> Void
  @State private var query = ""
  @State private var selection: Int?
  @FocusState private var searchFocused: Bool

  private var matches: [ExtensionOptionSearch.Option] {
    ExtensionOptionSearch.filter(options, query: query)
  }

  private var selectedValue: String? {
    ExtensionOptionSearch.selectedValue(in: matches, id: selection)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if options.count > 8 {
        HStack {
          TextField("搜索选项", text: $query)
            .textFieldStyle(.roundedBorder).focused($searchFocused)
            .accessibilityLabel("搜索扩展选项")
          if !query.isEmpty {
            Button {
              query = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
          }
          Text("\(matches.count)/\(options.count)")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
      }
      if matches.isEmpty {
        ContentUnavailableView(
          options.isEmpty ? "没有可选项" : "没有匹配的选项",
          systemImage: "magnifyingglass",
          description: Text(options.isEmpty ? "可以取消此请求。" : "尝试其他关键词或清除搜索。")
        )
        .frame(height: 180)
      } else {
        List(selection: $selection) {
          ForEach(matches) { option in
            Text(option.value).textSelection(.disabled)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.vertical, 4).tag(option.id)
          }
        }
        .listStyle(.inset).frame(height: min(320, CGFloat(matches.count) * 48 + 16))
        .accessibilityLabel("扩展选项；选择后按 Command Return 提交")
      }
      Divider()
      HStack {
        Text("选择后提交 · ⌘Return")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("取消", action: cancel).keyboardShortcut(.cancelAction)
        Button("提交选择") {
          if let value = selectedValue { answer(value) }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(selectedValue == nil)
      }
    }
    .onChange(of: query) { _, _ in selection = nil }
    .onAppear { searchFocused = options.count > 8 }
  }
}

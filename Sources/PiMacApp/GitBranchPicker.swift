import SwiftUI

/// A bounded, searchable local-ref picker rather than a 200-item native menu.
struct GitBranchPicker: View {
  let branches: [String]
  let current: String?
  let onSelect: (String) -> Void
  @State private var query = ""
  @FocusState private var focused: Bool

  private var matches: [String] {
    GitWorkspacePresentation.filteredBranches(branches, query: query, current: current)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索本地分支", text: $query).textFieldStyle(.roundedBorder)
          .focused($focused).accessibilityLabel("搜索本地分支")
        if !query.isEmpty {
          Button("清除", systemImage: "xmark.circle.fill") { query = "" }
            .labelStyle(.iconOnly).buttonStyle(.plain).help("清除分支搜索")
        }
      }
      Text("\(matches.count) / \(branches.count) 个本地分支")
        .font(.caption).foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          if matches.isEmpty {
            Text("没有匹配的分支").foregroundStyle(.secondary).padding()
          }
          ForEach(matches, id: \.self) { branch in
            Button {
              onSelect(branch)
            } label: {
              HStack {
                Image(
                  systemName: branch == current ? "checkmark.circle.fill" : "arrow.triangle.branch")
                Text(branch).lineLimit(1).truncationMode(.middle).help(branch)
                Spacer()
                if branch == current { Text("当前").font(.caption).foregroundStyle(.secondary) }
              }.padding(8).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(branch == current)
            .accessibilityLabel(branch == current ? "\(branch)，当前分支" : "切换到 \(branch)")
          }
        }
      }.frame(height: 240)
      Text("仅显示 Server 返回的本地分支；切换前需要确认。")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(14).frame(width: 360)
    .onAppear { focused = true }
  }
}

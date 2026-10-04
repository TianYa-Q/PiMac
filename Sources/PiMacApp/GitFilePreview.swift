import SwiftUI

struct GitFilePreview: View {
  @ObservedObject var server: T3DesktopClient
  let cwd: String
  let file: String
  @Environment(\.dismiss) private var dismiss
  @StateObject private var store = GitDiffPreviewStore()
  private var diff: String { store.preview?.text ?? "" }
  @State private var requestID = UUID()
  @State private var query = ""
  @State private var scope = GitDiffPresentation.Scope.all
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(file, systemImage: "doc.text.magnifyingglass").font(.headline).lineLimit(1).help(file)
        Spacer()
        Button("复制差异", systemImage: "doc.on.doc") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(diff, forType: .string)
        }
        .disabled(store.loading || store.failed || diff.isEmpty)
        .help("复制当前预览；截断时仅复制已显示的内容")
        Button("刷新", systemImage: "arrow.clockwise") { requestID = UUID() }
          .disabled(store.loading || !server.isConnected)
        Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if store.loading { ProgressView("正在读取差异…") }
      if store.failed {
        ContentUnavailableView {
          Label("差异读取失败", systemImage: "exclamationmark.triangle")
        } description: {
          Text("检查 Server 连接后重试。读取差异不会修改工作区。")
        } actions: {
          Button("重试", systemImage: "arrow.clockwise") { requestID = UUID() }
            .disabled(!server.isConnected)
        }
      }
      if store.preview?.truncated == true {
        Label("差异过大，当前预览已截断（本机最多显示 2 MB）。", systemImage: "info.circle").font(.caption)
          .foregroundStyle(
            .orange)
      }
      if !store.loading && !store.failed {
        HStack {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("搜索差异", text: $query).textFieldStyle(.roundedBorder)
            .focused($searchFocused).accessibilityLabel("搜索差异")
          if !query.isEmpty {
            Button("清除搜索", systemImage: "xmark.circle.fill") { query = "" }
              .labelStyle(.iconOnly).buttonStyle(.plain)
          }
          Picker("显示范围", selection: $scope) {
            ForEach(GitDiffPresentation.Scope.allCases) { Text($0.rawValue).tag($0) }
          }.pickerStyle(.segmented).frame(width: 160)
          Text("+\(store.presentation.additions)").foregroundStyle(.green)
          Text("−\(store.presentation.deletions)").foregroundStyle(.red)
        }.font(.caption.monospacedDigit())
        if store.presentation.truncated {
          Label("仅渲染前 10,000 行；复制差异仍包含已读取的完整文本。", systemImage: "info.circle")
            .font(.caption).foregroundStyle(.orange)
        }
        let lines = store.presentation.filtered(query: query, scope: scope)
        Text("显示 \(lines.count) / \(store.presentation.lines.count) 行 · 行号为差异文本位置")
          .font(.caption).foregroundStyle(.secondary)
        if diff.isEmpty {
          ContentUnavailableView(
            "没有文本差异", systemImage: "doc",
            description: Text("文件可能没有变更或是二进制文件。"))
        } else if lines.isEmpty {
          ContentUnavailableView(
            "没有匹配的行", systemImage: "magnifyingglass",
            description: Text("尝试其他关键词或切换显示范围。"))
        } else {
          ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(lines) { line in
                HStack(alignment: .top, spacing: 12) {
                  Text("\(line.id)").foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing).accessibilityHidden(true)
                  Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(color(for: line.kind)).textSelection(.enabled)
                }
                .font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color(for: line.kind).opacity(line.kind == .context ? 0 : 0.08))
              }
            }.padding(.vertical, 8)
          }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        }
      }
      Spacer(minLength: 0)
    }
    .padding(20).frame(width: 880, height: 600)
    .background {
      Button("搜索差异") { searchFocused = true }
        .keyboardShortcut("f", modifiers: .command).hidden()
    }
    .task(id: requestID) {
      await store.load {
        try await server.gitRPC(
          "review.getDiffPreview",
          payload: [
            "cwd": cwd,
            "file": ["path": file, "previousPath": NSNull(), "sourceKind": "working-tree"],
          ])
      }
    }
  }

  private func color(for kind: GitDiffPresentation.Kind) -> Color {
    switch kind {
    case .addition: .green
    case .deletion: .red
    case .header, .hunk: .blue
    case .context: .primary
    }
  }
}

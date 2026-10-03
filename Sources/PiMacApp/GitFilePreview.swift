import SwiftUI

struct GitFilePreview: View {
  let server: T3DesktopClient
  let cwd: String
  let file: String
  @Environment(\.dismiss) private var dismiss
  @StateObject private var store = GitDiffPreviewStore()
  private var diff: String { store.preview?.text ?? "" }
  @State private var requestID = UUID()

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
        if diff.isEmpty { Text("没有可显示的文本差异（可能是二进制文件）。").foregroundStyle(.secondary) }
        ScrollView([.horizontal, .vertical]) {
          Text(diff).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: true).padding(12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
      }
      Spacer(minLength: 0)
    }
    .padding(20).frame(width: 780, height: 540)
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
}

import SwiftUI

struct GitFilePreview: View {
  let server: T3DesktopClient
  let cwd: String
  let file: String
  @Environment(\.dismiss) private var dismiss
  @State private var diff = ""
  @State private var loading = true
  @State private var truncated = false
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(file, systemImage: "doc.text.magnifyingglass").font(.headline).lineLimit(1).help(file)
        Spacer()
        Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if loading { ProgressView("正在读取差异…") }
      if failed { ContentUnavailableView("差异读取失败", systemImage: "exclamationmark.triangle", description: Text("请关闭预览并刷新 Git 状态。")) }
      if truncated { Label("差异过大，Server 返回的预览已截断。", systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
      if !loading && !failed {
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
    .task {
      do {
        let result = try await server.gitRPC("review.getDiffPreview", payload: ["cwd": cwd,
          "file": ["path": file, "previousPath": NSNull(), "sourceKind": "working-tree"]])
        try Task.checkCancellation()
        let sources = (result["sources"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "working-tree" }
        diff = sources.compactMap { $0["diff"] as? String }.joined(separator: "\n")
        truncated = sources.contains { $0["truncated"] as? Bool == true }
        loading = false
      } catch is CancellationError {
        return
      } catch {
        failed = true
        loading = false
      }
    }
  }
}

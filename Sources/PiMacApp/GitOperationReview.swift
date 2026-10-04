import SwiftUI

/// Review the captured payload, not the live selection behind the modal.
struct GitOperationReview: View {
  @ObservedObject var store: GitWorkspaceStore
  @ObservedObject var server: T3DesktopClient
  let title: String
  let payload: [String: Any]
  let snapshotID: UUID
  let branch: String?
  let onConfirm: () -> Void
  @Environment(\.dismiss) private var dismiss

  private var expired: Bool { store.snapshotID != snapshotID || store.requiresRefresh }
  private var files: [String] { payload["filePaths"] as? [String] ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.title2.bold())
      Text(payload["cwd"] as? String ?? "").font(.caption.monospaced())
        .textSelection(.enabled)
      Label(branch ?? "Detached HEAD", systemImage: "arrow.triangle.branch")
      if let target = payload["refName"] as? String {
        Text("目标分支：\(target)").textSelection(.enabled)
      }
      if let message = payload["commitMessage"] as? String {
        Text("提交说明").font(.headline)
        ScrollView {
          Text(message).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .frame(maxHeight: 80)
      }
      if !files.isEmpty {
        Text("仅提交以下 \(files.count) 个文件（包含筛选外已选文件）").font(.headline)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(files, id: \.self) {
              Text($0).font(.caption.monospaced()).textSelection(.enabled)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: 160)
      }
      Text("提交会运行 Git hooks；推送或创建 PR 会访问远端。结果未确认时不会自动重试。此确认只绑定客户端快照，无法锁定其他程序的 Git 操作。")
        .font(.callout).foregroundStyle(.secondary)
      if expired {
        Label("状态已刷新，请取消并检查最新状态后重新确认。", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      }
      if !server.isConnected {
        Label("Server 未连接，操作不可用。", systemImage: "wifi.slash").foregroundStyle(.orange)
      }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("执行") {
          dismiss()
          onConfirm()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(expired || store.busy || store.loading || !server.isConnected)
      }
    }.padding(24).frame(width: 560)
  }
}

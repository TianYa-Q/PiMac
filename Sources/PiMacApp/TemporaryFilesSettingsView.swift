import AppKit
import SwiftUI

struct TemporaryFilesSettingsView: View {
  @ObservedObject var store: TemporaryFilesStore
  @ObservedObject var server: T3DesktopClient
  let projectCount: Int
  let clean: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 6) {
          Text("临时文件").font(.title2.weight(.semibold))
          Text("保留 3 天，过期内容移入废纸篓。")
            .font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Button(action: clean) {
          if store.isRunning {
            ProgressView().controlSize(.small)
          } else {
            Text("立即清理")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isRunning || !server.isConnected || projectCount == 0)
      }

      Toggle(isOn: $store.automaticCleanup) {
        VStack(alignment: .leading, spacing: 4) {
          Text("自动清理")
          Text("PiMac 运行期间每小时检查，统一管理 \(projectCount) 个工作区。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .toggleStyle(.switch)

      Divider()

      if !server.isConnected {
        Label("等待 Server 连接，暂不执行清理。", systemImage: "pause.circle")
          .font(.callout).foregroundStyle(.secondary)
      }
      if !store.errorMessage.isEmpty {
        Label(store.errorMessage, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.red).textSelection(.enabled)
      }
      if let record = store.records.first {
        HStack {
          Text("最近检查").font(.headline)
          Spacer()
          Text(record.date, format: .dateTime.month().day().hour().minute())
            .font(.caption).foregroundStyle(.secondary)
        }
        VStack(spacing: 0) {
          ForEach(Array(record.results.enumerated()), id: \.element.id) { index, result in
            if index > 0 { Divider().padding(.vertical, 12) }
            VStack(alignment: .leading, spacing: 5) {
              HStack {
                Text(result.name).font(.callout.weight(.medium))
                Spacer()
                Text(result.moved > 0 ? "已整理 \(result.moved) 项" : result.message)
                  .font(.callout).foregroundStyle(.secondary)
              }
              if result.moved > 0 {
                Text(
                  "\(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file)) 已移入废纸篓 · \(result.message)"
                )
                .font(.caption).foregroundStyle(.secondary)
              }
              ForEach(result.errors, id: \.self) { error in
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
              }
            }
          }
        }
      } else {
        Text(store.isRunning ? "正在检查临时目录…" : "尚未执行清理")
          .font(.callout).foregroundStyle(.secondary)
      }

      DisclosureGroup("清理规则与记录") {
        VStack(alignment: .leading, spacing: 10) {
          Text("仅处理已管理项目及 worktree 的 tmp/，按最近创建、修改或文件访问时间保留至少 3 天。")
          Text(
            "活跃任务、未结束的编辑批次、Git 跟踪文件、进程正在使用的文件，以及 .keep / .pimac-keep / *.lock / *.pid 均保留；不会跟随目录链接清理其他位置。"
          )
          Text("需要长期保留的任务目录放置 .keep；长期复用的工具应移到正式源码或测试目录。移入废纸篓不等于释放磁盘空间。")
          ForEach(store.records.prefix(10)) { record in
            VStack(alignment: .leading, spacing: 4) {
              Text(record.date, format: .dateTime.month().day().hour().minute())
                .fontWeight(.medium)
              ForEach(record.results) { result in
                Text(
                  "\(result.name)：移入 \(result.moved) 项，保留 \(result.retained) 项 · \(result.message)")
                if !result.items.isEmpty {
                  Text(result.items.joined(separator: "、")).textSelection(.enabled)
                }
              }
            }
          }
          Button("打开废纸篓") {
            NSWorkspace.shared.open(
              FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
          }
          .buttonStyle(.link)
        }
        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
      }
      .font(.callout)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

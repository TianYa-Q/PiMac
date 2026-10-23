import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 每次操作捕获目标会话，切换标签页不会把导出结果保存到另一会话名下。
struct SessionHTMLExportButton: View {
  @ObservedObject var server: T3DesktopClient
  let threadID: String?
  let title: String
  let isBusy: Bool
  @State private var exporting = false

  var body: some View {
    Button {
      chooseDestination()
    } label: {
      Label(exporting ? "正在导出…" : "导出 HTML…", systemImage: "square.and.arrow.up")
    }
    .disabled(threadID == nil || !server.isConnected || isBusy || exporting)
    .help("通过 Pi 原生功能导出完整会话、system prompt 和工具定义；历史会话会先恢复")
  }

  private func chooseDestination() {
    guard let threadID, !exporting else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.html]
    panel.nameFieldStringValue = Self.filename(title: title)
    panel.message = "文件包含完整会话、system prompt 和工具定义，可能包含敏感信息。历史会话使用恢复后的配置。"
    panel.canCreateDirectories = true
    panel.begin { response in
      guard response == .OK, let destination = panel.url else { return }
      exporting = true
      Task { @MainActor in
        defer { exporting = false }
        do {
          let html = try await server.exportSessionHTML(threadID: threadID)
          // 先取回完整结果再原子写入；失败不覆盖用户原有文件。
          try Data(html.utf8).write(to: destination, options: .atomic)
        } catch {
          // 右键菜单在异步返回前已销毁，不能把失败提示挂在菜单内容的 .alert 上。
          let alert = NSAlert()
          alert.messageText = "导出失败"
          alert.informativeText =
            "无法恢复、导出或保存会话。请确认会话已空闲、Server 已更新，且项目目录和 Pi 会话文件仍然存在。\n\(error.localizedDescription)"
          if let window = NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
          } else {
            alert.runModal()
          }
        }
      }
    }
  }

  static func filename(title: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: forbidden).joined(separator: "-")
    return String((cleaned.isEmpty ? "Pi 会话" : cleaned).prefix(100)) + ".html"
  }
}

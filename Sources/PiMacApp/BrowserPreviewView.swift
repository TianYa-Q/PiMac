import AppKit
import SwiftUI

struct BrowserPreviewButton: View {
  @ObservedObject var model: BrowserPreviewModel
  let hasThread: Bool

  var body: some View {
    Button {
      if model.detached { model.detach() } else { model.setVisible(!model.visible) }
    } label: {
      Image(systemName: "globe")
        .font(.system(size: 15, weight: .medium))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(model.visible ? Color.accentColor : Color.secondary)
    .disabled(!hasThread)
    .help(
      hasThread
        ? (model.detached ? "显示浏览器窗口" : model.visible ? "收起浏览器预览" : "打开浏览器预览") : "开始会话后可打开浏览器预览"
    )
    .accessibilityLabel("浏览器")
    .accessibilityValue(model.visible ? "已打开" : "已收起")
  }
}

/// 默认右侧工具面板；原生分隔条可调宽，弹出窗口只移动宿主，不重新建立浏览器会话。
struct BrowserPreviewWorkspace<Content: View>: View {
  @ObservedObject var server: T3DesktopClient
  let threadID: String?
  @ObservedObject var model: BrowserPreviewModel
  @ViewBuilder let content: () -> Content

  var body: some View {
    HSplitView {
      content()
        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
      if model.visible && !model.detached {
        BrowserPreviewPanel(model: model)
          .frame(minWidth: 300, idealWidth: 440, maxWidth: 1000, maxHeight: .infinity)
      }
    }
    .task(id: "\(threadID ?? "")-\(server.isConnected)") {
      await model.watch(server: server, threadID: threadID, connected: server.isConnected)
    }
    .onDisappear { model.stop() }
  }
}

@MainActor
final class BrowserPreviewWindowController: NSWindowController, NSWindowDelegate {
  private weak var model: BrowserPreviewModel?

  init(model: BrowserPreviewModel) {
    self.model = model
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "浏览器预览"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.backgroundColor = .windowBackgroundColor
    window.minSize = NSSize(width: 640, height: 480)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: BrowserPreviewPanel(model: model))
    super.init(window: window)
    window.delegate = self
    window.center()
  }
  required init?(coder: NSCoder) { nil }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // 先清除代理再由模型关闭宿主，避免 close 回调重入；连接不断开，回到侧栏。
    guard let model else { return true }
    model.dock()
    return false
  }
}

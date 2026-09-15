import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // SwiftPM 直接运行的可执行文件没有完整 .app 启动流程，AppKit 有时不会
    // 自动把它激活；窗口虽然可见，键盘事件却仍发往之前的应用。
    NSApp.setActivationPolicy(.regular)

    // `setActivationPolicy` 会创建 Dock 图块并重置之前设置的图标，因此必须
    // 在它之后从 SwiftPM 资源包中应用图标。
    let icon = Bundle.module.url(forResource: "AppIcon", withExtension: "png")
      .flatMap(NSImage.init(contentsOf:))
    applyAppIcon(icon)

    DispatchQueue.main.async {
      // 裸可执行文件的默认图标仍可能覆盖 applicationIconImage；使用自定义
      // Dock tile 可确保 `swift run` 和打包后的应用显示一致。
      self.applyAppIcon(icon)
      NSApp.activate(ignoringOtherApps: true)
      guard let window = NSApp.windows.first else { return }
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.titlebarSeparatorStyle = .none
      window.makeKeyAndOrderFront(nil)
    }
  }

  private func applyAppIcon(_ icon: NSImage?) {
    guard let icon else { return }
    NSApp.applicationIconImage = icon

    let iconView = NSImageView(frame: NSRect(origin: .zero, size: NSApp.dockTile.size))
    iconView.image = icon
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.autoresizingMask = [.width, .height]
    NSApp.dockTile.contentView = iconView
    NSApp.dockTile.display()
  }
}

@main
struct PiMacApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var workspace = WorkspaceModel()

  var body: some Scene {
    WindowGroup {
      WorkspaceView()
        .environmentObject(workspace)
        .onDisappear { workspace.disconnectAll() }
    }
    .defaultSize(width: 1120, height: 760)
    .windowToolbarStyle(.unifiedCompact(showsTitle: false))
  }
}

private struct WorkspaceView: View {
  @EnvironmentObject private var workspace: WorkspaceModel

  var body: some View {
    if let tab = workspace.tabs.first(where: { $0.id == workspace.selectedTabID }) {
      ContentView()
        .environmentObject(tab.model)
        .environmentObject(workspace.extensionUI)
        .id(tab.id)
    } else {
      ProgressView()
    }
  }
}

extension AppModel {
  var clientConnectedForCommands: Bool {
    if case .connected = connectionState { return true }
    return false
  }
}

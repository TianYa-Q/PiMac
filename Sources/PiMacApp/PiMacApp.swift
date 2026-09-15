import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // SwiftPM 直接运行的可执行文件没有完整 .app 启动流程，AppKit 有时不会
    // 自动把它激活；窗口虽然可见，键盘事件却仍发往之前的应用。
    NSApp.setActivationPolicy(.regular)
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
      guard let window = NSApp.windows.first else { return }
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.titlebarSeparatorStyle = .none
      window.makeKeyAndOrderFront(nil)
    }
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

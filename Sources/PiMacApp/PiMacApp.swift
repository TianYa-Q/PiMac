import AppKit
import SwiftUI

/// Enabled only by scripts/dev.py; packaged apps never watch or relaunch themselves.
@MainActor
final class DevelopmentReloader: ObservableObject {
  private let executable: URL?
  private var originalModification: Date?
  private var pendingSince: Date?
  private var reloading = false

  init() {
    let path = ProcessInfo.processInfo.environment["PIMAC_DEV_RELOAD_PATH"]
    let running = Bundle.main.executableURL?.standardizedFileURL
    executable = path.flatMap { URL(fileURLWithPath: $0).standardizedFileURL == running ? running : nil }
    originalModification = executable.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
  }

  func check(workspace: WorkspaceModel) {
    guard !reloading, let executable, let originalModification,
      let modified = try? executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
      modified > originalModification
    else { return }
    if pendingSince == nil { pendingSince = .now; return }
    guard let pendingSince, Date.now.timeIntervalSince(pendingSince) >= 2,
      workspace.canRestartSafely
    else { return }

    // Wait for the old process to exit before exec-ing the new binary (Telegram long polling
    // must not have two owners). Retain the development environment across the relaunch.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec \"$2\"", "--", "\(ProcessInfo.processInfo.processIdentifier)", executable.path]
    do {
      try process.run()
      reloading = true
      NSApp.terminate(nil)
    } catch {
      NSLog("Pi Mac development reload failed: %@", String(describing: error))
    }
  }
}

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
  @StateObject private var developmentReloader = DevelopmentReloader()

  var body: some Scene {
    WindowGroup {
      WorkspaceView()
        .environmentObject(workspace)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
          developmentReloader.check(workspace: workspace)
        }
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
      ContentView(tabID: tab.id)
        .environmentObject(tab.model)
        .environmentObject(workspace.extensionUI)
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

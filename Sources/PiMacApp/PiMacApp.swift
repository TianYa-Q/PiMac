import AppKit
import SwiftUI

/// Enabled only by scripts/dev.py; packaged apps never watch or relaunch themselves.
@MainActor
final class DevelopmentReloader: ObservableObject {
  private let executable: URL?
  private var originalModification: Date?
  private let revisionFile: URL?
  private let stateFile: URL?
  private let requestFile: URL?
  private var idleSince: Date?
  private var pendingSince: Date?
  private var reloading = false
  private var relaunchProcess: Process?

  init() {
    let path = ProcessInfo.processInfo.environment["PIMAC_DEV_RELOAD_PATH"]
    let running = Bundle.main.executableURL?.standardizedFileURL
    executable = path.flatMap {
      URL(fileURLWithPath: $0).standardizedFileURL == running ? running : nil
    }
    revisionFile = ProcessInfo.processInfo.environment["PIMAC_DEV_RELOAD_REVISION"].map {
      URL(fileURLWithPath: $0)
    }
    stateFile = ProcessInfo.processInfo.environment["PIMAC_DEV_STATE_PATH"].map {
      URL(fileURLWithPath: $0)
    }
    requestFile = ProcessInfo.processInfo.environment["PIMAC_DEV_REQUEST_PATH"].map {
      URL(fileURLWithPath: $0)
    }
    originalModification = (revisionFile ?? executable).flatMap {
      (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date
    }
  }

  func check(workspace: WorkspaceModel, appDelegate: AppDelegate) {
    guard !reloading, executable != nil else { return }
    let blockers = workspace.restartBlockers
    if blockers.isEmpty {
      if idleSince == nil { idleSince = .now }
    } else {
      idleSince = nil
    }
    // Publish a fresh, atomic heartbeat. The watcher never builds based on a
    // missing/stale heartbeat, and waits for two seconds of continuous idle.
    if let stateFile {
      let idle = idleSince.map { Date.now.timeIntervalSince($0) >= 2 } ?? false
      let state: [String: Any] = ["timestamp": Date.now.timeIntervalSince1970, "idle": idle]
      if let data = try? JSONSerialization.data(withJSONObject: state) {
        try? data.write(to: stateFile, options: .atomic)
      }
    }
    let requested = requestFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    let status = requested
      ? (blockers.isEmpty ? "源码已更新，等待空闲构建…" : "源码待构建：\(blockers.joined(separator: "、"))")
      : ""
    if workspace.developmentReloadStatus != status {
      workspace.developmentReloadStatus = status
    }
    // Do not restart a previously built revision while newer edits are pending.
    guard !requested, let executable, let originalModification,
      let modified = (try? FileManager.default.attributesOfItem(
        atPath: (revisionFile ?? executable).path)[.modificationDate]) as? Date,
      modified > originalModification
    else { return }
    if pendingSince == nil {
      pendingSince = .now
      return
    }
    workspace.developmentReloadStatus = blockers.isEmpty
      ? "新版构建就绪，准备空闲重启…" : "新版等待重启：\(blockers.joined(separator: "、"))"
    guard let pendingSince, Date.now.timeIntervalSince(pendingSince) >= 2,
      blockers.isEmpty
    else { return }

    reloading = true
    Task {
      // Drain services while the main actor is alive so the child finalizers
      // and termination handler finish before launching a replacement.
      workspace.developmentReloadStatus = "正在停止旧版服务，等待安全重启…"
      do {
        // Must precede disconnectAll(): upstream otherwise treats this as quit
        // and deletes the tunnel instead of handing it to the replacement.
        try workspace.t3Bridge.prepareForUpdateRestart()
      } catch {
        workspace.developmentReloadStatus = "自动重启已取消：无法准备隧道交接，请检查服务目录权限。"
        reloading = false
        return
      }
      workspace.disconnectAll()
      guard await workspace.t3Bridge.stopAndWait() else {
        workspace.developmentReloadStatus = "自动重启已取消：旧 T3 服务或服务锁未释放，请停止监听器后检查。"
        NSLog("Pi Mac development reload cancelled: T3 shutdown barrier failed")
        return
      }
      workspace.developmentReloadStatus = "旧版服务已停止，正在重启应用…"
      // Retain the development environment, but never run two app owners.
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = [
        "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec \"$2\"", "--",
        "\(ProcessInfo.processInfo.processIdentifier)", executable.path,
      ]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
        relaunchProcess = process
        appDelegate.servicesStoppedForReload = true
        NSApp.terminate(nil)
      } catch {
        workspace.developmentReloadStatus = "自动重启失败，请停止监听器后重新启动。"
        NSLog("Pi Mac development reload failed: %@", String(describing: error))
      }
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var workspace: WorkspaceModel?
  private var terminating = false
  var servicesStoppedForReload = false

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // DevelopmentReloader has already drained services and passed the barrier.
    // Running the asynchronous termination barrier a second time is unnecessary.
    guard !servicesStoppedForReload, let workspace else { return .terminateNow }
    guard !terminating else { return .terminateLater }
    terminating = true
    Task {
      workspace.disconnectAll()
      let stopped = await workspace.t3Bridge.stopAndWait()
      if !stopped {
        terminating = false
        workspace.developmentReloadStatus = "退出已暂停：等待本机 T3 Server 关闭，请稍后重试。"
      }
      sender.reply(toApplicationShouldTerminate: stopped)
    }
    return .terminateLater
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // SwiftPM 直接运行的可执行文件没有完整 .app 启动流程，AppKit 有时不会
    // 自动把它激活；窗口虽然可见，键盘事件却仍发往之前的应用。
    NSApp.setActivationPolicy(.regular)
    Task { await TaskStatusNotifications.shared.requestPermission() }

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
          developmentReloader.check(workspace: workspace, appDelegate: appDelegate)
        }
        .onAppear { appDelegate.workspace = workspace }
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

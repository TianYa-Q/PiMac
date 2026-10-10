import AppKit
import SwiftUI

/// Enabled only by scripts/dev.py. The watcher owns every replacement process.
@MainActor
final class DevelopmentReloader: ObservableObject {
  private let executable: URL?
  private var originalModification: Date?
  private let revisionFile: URL?
  private let stateFile: URL?
  private let requestFile: URL?
  private let editDirectory: URL?
  private var reload = DevelopmentReloadState()
  private let restartFile: URL?
  private var lastStatus = ""

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
    editDirectory = ProcessInfo.processInfo.environment["PIMAC_DEV_EDIT_DIRECTORY"].map {
      URL(fileURLWithPath: $0)
    }
    restartFile = ProcessInfo.processInfo.environment["PIMAC_DEV_RESTART_PATH"].map {
      URL(fileURLWithPath: $0)
    }
    originalModification = (revisionFile ?? executable).flatMap {
      (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date
    }
  }

  func check(workspace: WorkspaceModel, appDelegate: AppDelegate) {
    guard let executable else { return }
    guard reload.phase == .watching else {
      publishHeartbeat(idle: false)
      return
    }
    var blockers = workspace.restartBlockers
    if let blocker = PS5GatewayController.shared.restartBlocker {
      blockers.append(blocker)
    }
    if DevelopmentReloadState.editsPending(directory: editDirectory) {
      blockers.append("代码修改批次尚未完成")
    }
    let idle = reload.observeIdle(blockers.isEmpty, now: .now)
    // Publish a fresh, atomic heartbeat. The watcher never builds based on a
    // missing/stale heartbeat, and waits for two seconds of continuous idle.
    publishHeartbeat(idle: idle)
    let requested = requestFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    let status =
      requested
      ? (blockers.isEmpty ? "源码已更新，等待空闲构建…" : "源码待构建：\(blockers.joined(separator: "、"))")
      : ""
    // Do not restart a previously built revision while newer edits are pending.
    guard !requested, let originalModification,
      let modified =
        (try? FileManager.default.attributesOfItem(
          atPath: (revisionFile ?? executable).path)[.modificationDate]) as? Date,
      modified > originalModification
    else {
      setStatus(status, workspace: workspace)
      return
    }
    setStatus(
      blockers.isEmpty
        ? "新版构建就绪，准备空闲重启…" : "新版等待重启：\(blockers.joined(separator: "、"))",
      workspace: workspace)
    guard idle else { return }
    // Old watchers cannot own the replacement. Fail before disconnecting anything.
    guard restartFile != nil else {
      fail("监听器版本过旧，请重新运行 scripts/dev.py（服务未停止）。", workspace: workspace)
      return
    }
    reload.begin()
    publishHeartbeat(idle: false)
    Task {
      // Drain services while the main actor is alive so the child finalizers
      // and termination handler finish before launching a replacement.
      setStatus("正在停止旧版服务，等待安全重启…", workspace: workspace)
      do {
        // Must precede disconnectAll(): upstream otherwise treats this as quit
        // and deletes the tunnel instead of handing it to the replacement.
        try workspace.t3Bridge.prepareForUpdateRestart()
      } catch {
        fail("无法准备隧道交接，请检查服务目录权限。", workspace: workspace)
        return
      }
      workspace.disconnectAll()
      guard await workspace.t3Bridge.stopAndWait() else {
        fail("旧 T3 服务或服务锁未释放，请重新运行监听器。", workspace: workspace)
        return
      }
      do {
        guard let restartFile else { throw CocoaError(.fileNoSuchFile) }
        let intent: [String: Any] = [
          "pid": ProcessInfo.processInfo.processIdentifier,
          "timestamp": Date.now.timeIntervalSince1970,
        ]
        try JSONSerialization.data(withJSONObject: intent).write(to: restartFile, options: .atomic)
        reload.readyToExit()
        publishHeartbeat(idle: false)
        setStatus("旧版服务已停止，正在退出应用，由监听器启动新版…", workspace: workspace)
        appDelegate.servicesStoppedForReload = true
        NSApp.terminate(nil)
        // AppKit can cancel termination (for example, a modal window). Never
        // leave a live UI in a permanent 'exiting' state, or start a second owner.
        try? await Task.sleep(for: .seconds(10))
        try? FileManager.default.removeItem(at: restartFile)
        appDelegate.servicesStoppedForReload = false
        fail("应用未能退出，请重新运行监听器。", workspace: workspace)
      } catch {
        fail("无法提交重启请求，请重新运行监听器。", workspace: workspace)
      }
    }
  }

  private func publishHeartbeat(idle: Bool) {
    guard let stateFile else { return }
    let state: [String: Any] = [
      "timestamp": Date.now.timeIntervalSince1970, "idle": idle,
      "pid": ProcessInfo.processInfo.processIdentifier, "phase": reload.phase.rawValue,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: state) {
      try? data.write(to: stateFile, options: .atomic)
    }
  }

  private func setStatus(_ status: String, workspace: WorkspaceModel) {
    workspace.developmentReloadStatus = status
    if status != lastStatus {
      if !status.isEmpty {
        NSLog("Pi Mac development reload [%@]: %@", reload.phase.rawValue, status)
      }
      lastStatus = status
    }
  }

  private func fail(_ message: String, workspace: WorkspaceModel) {
    reload.fail()
    publishHeartbeat(idle: false)
    setStatus("自动重启失败：\(message)", workspace: workspace)
  }
}

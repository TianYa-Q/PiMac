import AppKit
import SwiftUI
import Testing

@testable import PiMacApp

@MainActor
struct PiMacNativeCaptureTests {
  // 常规回归不生成截图；仅显式调用捕获脚本时启用，复用仓库构建缓存。
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PIMAC_CAPTURE_FIXTURE"] != nil))
  func capture() async throws {
    let env = ProcessInfo.processInfo.environment
    let fixturePath = try #require(env["PIMAC_CAPTURE_FIXTURE"])
    let output = try #require(env["PIMAC_CAPTURE_OUTPUT"])
    let fixture = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        as? [String: Any])
    let shell = try #require(fixture["shell"] as? [String: Any])
    let selectedID = try #require(fixture["selectedThreadID"] as? String)
    let width = (fixture["width"] as? NSNumber)?.doubleValue ?? 1100
    let height = (fixture["height"] as? NSNumber)?.doubleValue ?? 800
    #expect(width >= 320 && width <= 3000 && height >= 200 && height <= 2000)

    // 使用本地 shell fixture，不恢复用户状态，也不启动真实 Server。
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    workspace.server.applyShell(shell)
    _ = try #require(workspace.server.thread(selectedID))
    let tab = try #require(workspace.tabs.first)
    workspace.selectedTabID = tab.id
    tab.model.currentSessionPath = "t3:\(selectedID)"
    if let detail = fixture["detail"] as? [String: Any] { tab.model.apply(detail) }
    if let text = fixture["composerText"] as? String { tab.model.composerText = text }
    tab.model.composerContext = T3MessageContext.read(fixture["composerContext"])
    let suite = "PiMacNativeCaptureTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let lidController = LidSleepController(defaults: defaults, restoreSleep: { nil })
    defer {
      lidController.stop()
      defaults.removePersistentDomain(forName: suite)
    }
    let page: AnyView
    if fixture["page"] as? String == "lidSleep" {
      page = AnyView(LidSleepSettingsView(controller: lidController).padding(24))
    } else {
      page = AnyView(
        ContentView(tabID: tab.id)
          .environmentObject(tab.model)
          .environmentObject(workspace)
          .environmentObject(workspace.extensionUI))
    }
    let host = NSHostingView(
      rootView:
        page
        .frame(width: width, height: height)
        .preferredColorScheme(fixture["theme"] as? String == "light" ? .light : .dark))
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    // 让 SwiftUI 的 task（例如展开选中会话祖先）跑完；WebKit 应另用明确加载条件。
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: output))
  }
}

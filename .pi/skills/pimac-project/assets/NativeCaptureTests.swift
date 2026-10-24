import AppKit
import SwiftUI
import Testing

@testable import PiMacApp

@MainActor
struct PiMacNativeCaptureTests {
  @Test func capture() async throws {
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
    let host = NSHostingView(
      rootView: ContentView(tabID: tab.id)
        .environmentObject(tab.model)
        .environmentObject(workspace)
        .environmentObject(workspace.extensionUI)
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

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
    if fixture["connectionReady"] as? Bool == true {
      workspace.server.didCompletePoll()
      tab.model.connectionState = .connected
      tab.model.projectURL = URL(fileURLWithPath: "/tmp/pimac-ui-fixture")
      tab.model.selectedModelId = "test/model"
    }
    if let text = fixture["composerText"] as? String { tab.model.composerText = text }
    tab.model.composerContext = T3MessageContext.read(fixture["composerContext"])
    if fixture["draftAccountSwitch"] as? Bool == true {
      tab.model.currentSessionPath = ""
      tab.model.selectedModelId = "openai/gpt-5"
      workspace.server.didCompletePoll()
      if let status = fixture["accountStatus"] as? [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: status)
        workspace.extensionUI.handle(
          [
            "method": "setStatus", "id": "capture-accounts", "statusKey": "account-usage-gui",
            "statusText": String(decoding: data, as: UTF8.self),
          ], from: tab.model)
      }
    }
    let suite = "PiMacNativeCaptureTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let lidController = LidSleepController(defaults: defaults, restoreSleep: { nil })
    defer {
      lidController.stop()
      defaults.removePersistentDomain(forName: suite)
    }
    let page: AnyView
    if fixture["page"] as? String == "versions" {
      let versions = VersionManagerModel(
        current: "1.5.0", latest: "1.5.0",
        extensions: [
          ManagedExtension(
            source: "pi-antigravity", path: "", scope: "内部管理",
            kind: .npm(name: "pi-antigravity", pinned: true),
            currentVersion: "0.11.0", latestVersion: "0.11.0"),
          ManagedExtension(
            source: "pi-web-access", path: "", scope: "内部管理",
            kind: .npm(name: "pi-web-access", pinned: true),
            currentVersion: "0.47.0", latestVersion: "0.47.0"),
          ManagedExtension(
            source: "@schovest/pi-goal", path: "", scope: "内部管理",
            kind: .npm(name: "@schovest/pi-goal", pinned: true),
            currentVersion: "0.2.1", latestVersion: "0.2.1"),
        ])
      page = AnyView(
        SettingsView(
          path: "fixture", projectURL: nil, telegram: workspace.telegram, workspace: workspace,
          initialTab: .updates, versionModel: versions, save: { _ in }))
    } else if fixture["page"] as? String == "goalCreation" {
      page = AnyView(
        GoalCreationForm(
          objective: .constant(fixture["objective"] as? String ?? "实现 CSV 导出并运行测试"),
          unavailableReason: nil, onDismiss: {}, onStart: { _ in false }))
    } else if fixture["page"] as? String == "usage" {
      let summary = try #require(fixture["usageSummary"] as? [String: Any])
      let snapshot = try T3UsageSummary.snapshot(summary, period: .month)
      let model = UsageDashboardModel { _ in snapshot }
      model.snapshot = fixture["usageState"] as? String == "loading" ? UsageSnapshot() : snapshot
      model.isLoading = ["loading", "refreshing"].contains(fixture["usageState"] as? String ?? "")
      let hoveredDate: Date?
      if let dateString = fixture["usageHoveredDate"] as? String {
        let parsedDate: Date = try #require(ISO8601DateFormatter().date(from: dateString))
        hoveredDate = parsedDate
        _ = try #require(snapshot.day(at: hoveredDate, calendar: .current))
      } else {
        hoveredDate = nil
      }
      page = AnyView(
        UsageDashboardView(model: model, automaticallyLoads: false, hoveredDate: hoveredDate))
    } else if fixture["page"] as? String == "accounts" {
      defaults.set(true, forKey: "accountQuotaExpanded")
      page = AnyView(
        CodexAccountsView()
          .environmentObject(tab.model)
          .environmentObject(workspace.extensionUI)
          .defaultAppStorage(defaults)
          .padding(16)
          .background(Color(nsColor: .windowBackgroundColor)))
    } else if fixture["page"] as? String == "lidSleep" {
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
    let composited = fixture["compositedCapture"] as? Bool == true
    if composited { window.orderFrontRegardless() }
    defer {
      if composited { window.orderOut(nil) }
      window.contentView = nil
    }
    // 让 SwiftUI 的 task（例如展开选中会话祖先）跑完；WebKit 应另用明确加载条件。
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
    let bitmap: NSBitmapImageRep
    if composited {
      // layer-backed 原生控件需捕获窗口合成结果，cacheDisplay 可能只得到黑色区域。
      window.displayIfNeeded()
      let image = try #require(
        CGWindowListCreateImage(
          .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
          [.boundsIgnoreFraming, .bestResolution]))
      bitmap = NSBitmapImageRep(cgImage: image)
    } else {
      bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
    }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: output))
  }
}

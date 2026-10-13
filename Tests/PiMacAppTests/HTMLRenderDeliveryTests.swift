import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PiMacApp

@MainActor
struct HTMLRenderDeliveryTests {
  @Test(.timeLimit(.minutes(1)))
  func officialToolPageLoadsLiveAndAfterHistoryRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = repository.appendingPathComponent("sidecars/t3-server/tests/fixtures/pi.mjs")
    let binary = root.appendingPathComponent("fixture-pi")
    try "#!/bin/sh\nexec node \"\(fixture.path)\" \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "pimac-html-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(binary.path, forKey: "piPath")
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults)
    let client = T3DesktopClient(defaults: defaults)
    defer {
      client.stop()
      service.stop()
      workspace.disconnectAll()
    }
    try service.start(
      workspace: workspace, token: T3NetworkEndpoint.secret(),
      stateDirectory: root.appendingPathComponent("state"))
    client.start(service: service)
    try await client.waitUntilReady()
    let projectID = try await client.ensureProject(root)
    let threadID = UUID().uuidString
    try await client.dispatch([
      "type": "thread.create", "threadId": threadID, "projectId": projectID, "title": "HTML render",
      "modelSelection": ["instanceId": "pi", "model": "test/model"],
      "runtimeMode": "full-access", "interactionMode": "default", "branch": NSNull(),
      "worktreePath": NSNull(),
    ])
    var latest: [String: Any] = [:]
    let owner = UUID()
    client.watch(threadID, owner: owner) { latest = $0 }
    try await client.dispatch([
      "type": "message.dispatch", "threadId": threadID, "messageId": UUID().uuidString,
      "text": "html-render", "attachments": [], "dispatchMode": ["type": "start_immediately"],
    ])
    func page() -> T3HTMLRender? {
      let thread = latest["thread"] as? [String: Any]
      return (thread?["messages"] as? [[String: Any]] ?? []).compactMap {
        $0["htmlRender"] as? T3HTMLRender
      }.first
    }
    func document() -> String? {
      let thread = latest["thread"] as? [String: Any]
      return (thread?["messages"] as? [[String: Any]] ?? []).compactMap {
        $0["htmlDocument"] as? String
      }.first
    }
    for _ in 0..<250 {
      if document() != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    let reference = try #require(page())
    let html = try #require(document())
    // 在任何显式加载之前移走附件，证明 live hydration 自己已完成下载和缓存。
    // 否则这里先调用 htmlRenderDocument 会掩盖“必须由视图/reopen 触发下载”的回归。
    let files =
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects
      as? [URL] ?? []
    let saved = try #require(
      files.first { $0.lastPathComponent == reference.attachmentID + ".html" })
    try FileManager.default.moveItem(at: saved, to: saved.appendingPathExtension("cached"))
    #expect(try await client.htmlRenderDocument(reference) == html)
    #expect(html.contains("侧栏前后对比"))
    #expect(html.contains("t3-theme"))
    #expect(html.contains("ui/notifications/size-changed"))
    var measuredHeight: Double?
    var renderError: String?
    let host = NSHostingView(
      rootView: HTMLRenderWebView(
        html: html, dark: true,
        onHeight: { measuredHeight = $0 }, onError: { renderError = $0 }, onLink: { _ in }
      )
      .frame(width: 728, height: 300))
    host.frame = NSRect(x: 0, y: 0, width: 728, height: 300)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    host.layoutSubtreeIfNeeded()
    for _ in 0..<100 {
      if measuredHeight != nil || renderError != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(renderError == nil)
    #expect(measuredHeight != nil)
    client.unwatch(owner: owner)
    latest = [:]
    client.watch(threadID, owner: owner) { latest = $0 }
    for _ in 0..<100 {
      if page() != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(page() == reference)
    #expect(document() == html)
    #expect(try await client.htmlRenderDocument(reference) == html)
    let missing = T3HTMLRender(
      attachmentID: "\(threadID)-00000000-0000-4000-8000-000000000000-html",
      title: "不存在的页面", height: 200, measurements: [])
    await #expect(throws: (any Error).self) {
      try await client.htmlRenderDocument(missing)
    }
  }
}

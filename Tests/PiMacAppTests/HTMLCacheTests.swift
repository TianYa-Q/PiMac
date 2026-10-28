import AppKit
import SwiftUI
import Testing
import WebKit

@testable import PiMacApp

@Suite(.serialized)
struct HTMLDocumentCacheTests {
  private func directory() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/html-cache/tests/\(UUID())")
  }

  @Test func persistsAcrossInstancesAndSeparatesServersAndAttachments() async throws {
    let root = directory()
    let first = T3HTMLDocumentCache(directory: root)
    #expect(
      try await first.document(key: "server-a|page-html") { "<h1>saved</h1>" } == "<h1>saved</h1>")
    let restarted = T3HTMLDocumentCache(directory: root)
    let html = try await restarted.document(key: "server-a|page-html") {
      Issue.record("Persisted HTML must not download again")
      return "unexpected"
    }
    #expect(html == "<h1>saved</h1>")
    #expect(try await restarted.document(key: "server-b|page-html") { "server B" } == "server B")
    #expect(try await restarted.document(key: "server-a|other-html") { "other" } == "other")
    let permissions =
      try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
    #expect(permissions == 0o700)
  }

  @Test func corruptDiskAndDownloadFailureRecoverWithoutCachingFailure() async throws {
    let root = directory()
    let first = T3HTMLDocumentCache(directory: root)
    _ = try await first.document(key: "page") { "original" }
    let file = root.appendingPathComponent(T3HTMLDocumentCache.digest("page") + ".json")
    try Data("corrupt".utf8).write(to: file)
    let cache = T3HTMLDocumentCache(directory: root)
    enum Failure: Error { case offline }
    await #expect(throws: Failure.self) {
      try await cache.document(key: "page") { throw Failure.offline }
    }
    #expect(try await cache.document(key: "page") { "recovered" } == "recovered")
    let restarted = T3HTMLDocumentCache(directory: root)
    #expect(try await restarted.document(key: "page") { "bad" } == "recovered")
    await #expect(throws: T3DesktopClient.ClientError.self) {
      try await cache.document(key: "empty") { "" }
    }
    #expect(try await cache.document(key: "empty") { "nonempty" } == "nonempty")
  }

  @Test func concurrentReadsShareOneDownload() async throws {
    actor Downloads {
      var count = 0
      func load() async throws -> String {
        count += 1
        try await Task.sleep(for: .milliseconds(50))
        return "shared"
      }
    }
    let downloads = Downloads()
    let cache = T3HTMLDocumentCache(directory: directory())
    try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<8 {
        group.addTask { try await cache.document(key: "same") { try await downloads.load() } }
      }
      for try await result in group { #expect(result == "shared") }
    }
    #expect(await downloads.count == 1)
  }

  @Test func memoryEvictsLeastRecentlyUsedInsteadOfClearingEverything() async throws {
    // 禁止落盘以单独验证内存 LRU；每条恰好 4 字节，总共只能容纳两条。
    let cache = T3HTMLDocumentCache(directory: directory(), memoryLimit: 8, diskLimit: 0)
    _ = try await cache.document(key: "a") { "aaaa" }
    _ = try await cache.document(key: "b") { "bbbb" }
    _ = try await cache.document(key: "a") {
      Issue.record("a should be cached")
      return "bad"
    }
    _ = try await cache.document(key: "c") { "cccc" }
    #expect(try await cache.document(key: "a") { "bad" } == "aaaa")
    #expect(try await cache.document(key: "b") { "newb" } == "newb")
  }

  @Test func diskEvictionStaysBounded() async throws {
    let root = directory()
    let cache = T3HTMLDocumentCache(directory: root, memoryLimit: 0, diskLimit: 500)
    _ = try await cache.document(key: "a") { String(repeating: "a", count: 180) }
    _ = try await cache.document(key: "b") { String(repeating: "b", count: 180) }
    let files = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.fileSizeKey])
    let bytes = try files.reduce(0) {
      try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    #expect(bytes <= 500)
    #expect(files.count == 1)
    #expect(try await cache.document(key: "a") { "reloaded" } == "reloaded")
  }
}

@MainActor
@Suite(.serialized)
struct HTMLWebViewCacheTests {
  @Test(.timeLimit(.minutes(1)))
  func localServerCacheIdentitySurvivesRestart() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/html-cache/tests/\(UUID())")
    let defaults = try #require(UserDefaults(suiteName: "html-cache-\(root.lastPathComponent)"))
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    defer { defaults.removePersistentDomain(forName: "html-cache-\(root.lastPathComponent)") }
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults, stateDirectory: root)
    defer {
      service.stop()
      workspace.disconnectAll()
    }
    var namespaces: [String] = []
    for _ in 0..<2 {
      try startT3ProtocolFixture(
        service: service, workspace: workspace, stateDirectory: root, binary: nil,
        model: "test/model")
      for _ in 0..<200 where service.serverURL == nil {
        try await Task.sleep(for: .milliseconds(50))
      }
      let namespace = try #require(service.assetCacheNamespace)
      #expect(namespace.hasPrefix("local:"))
      namespaces.append(namespace)
      #expect(await service.stopAndWait())
      #expect(service.assetCacheNamespace == nil)
    }
    #expect(namespaces[0] == namespaces[1])
  }

  @Test func retainsPageStateEvictsAndRejectsTerminatedPages() async throws {
    let cache = HTMLRenderWebViewCache(capacity: 1)
    let view = WKWebView()
    view.loadHTMLString("<html><body>cached</body></html>", baseURL: nil)
    for _ in 0..<100 {
      if !view.isLoading,
        (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete"
      {
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    _ = try await view.evaluateJavaScript("window.savedState = 42")
    cache.store(view, key: "first", dark: true, height: 320)
    let hit = try #require(cache.take(key: "first"))
    #expect(hit.view === view)
    #expect(hit.height == 320)
    #expect(try await hit.view.evaluateJavaScript("window.savedState") as? Int == 42)
    #expect(cache.take(key: "first") == nil)  // 正在展示的视图不能被再次租出。
    cache.store(view, key: "first", dark: true, height: 320)
    cache.store(WKWebView(), key: "second", dark: false, height: nil)
    #expect(cache.take(key: "first") == nil)
    let second = try #require(cache.take(key: "second"))
    second.webViewWebContentProcessDidTerminate(second.view)
    #expect(!second.valid)
    cache.store(view, key: "dead", dark: true, height: nil)
    view.navigationDelegate?.webViewWebContentProcessDidTerminate?(view)
    #expect(cache.take(key: "dead") == nil)
  }

  @Test func remountReusesRenderedWebViewWithoutLoadingAgain() async throws {
    let page = HTMLRenderWebView(
      html: "<p>retained page</p>", dark: true, cacheIdentity: UUID().uuidString,
      onHeight: { _ in }, onError: { _ in Issue.record("Unexpected WebKit error") },
      onLink: { _ in })
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 728, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false)
    defer { window.contentView = nil }
    func find(_ view: NSView) -> WKWebView? {
      if let web = view as? WKWebView { return web }
      return view.subviews.compactMap { find($0) }.first
    }
    var host: NSHostingView<HTMLRenderWebView>? = NSHostingView(rootView: page)
    host?.frame = window.frame
    window.contentView = host
    host?.layoutSubtreeIfNeeded()
    let first = try #require(host.flatMap { find($0) })
    var ready = false
    for _ in 0..<100 {
      if !first.isLoading,
        (try? await first.evaluateJavaScript("document.getElementById('page') !== null")) as? Bool
          == true
      {
        ready = true
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(ready)
    _ = try await first.evaluateJavaScript("window.cachedMarker = 42")
    let bounds = first.frame.size
    window.contentView = nil
    host = nil
    try await Task.sleep(for: .milliseconds(100))
    let secondHost = NSHostingView(rootView: page)
    secondHost.frame = window.frame
    window.contentView = secondHost
    secondHost.layoutSubtreeIfNeeded()
    let second = try #require(find(secondHost))
    #expect(second === first)
    #expect(!second.isLoading)
    #expect(second.frame.size == bounds)
    #expect(try await second.evaluateJavaScript("window.cachedMarker") as? Int == 42)
  }

  @Test func releasesIdlePagesAfterDeadline() async throws {
    let cache = HTMLRenderWebViewCache(lifetime: 0.02)
    weak var released: WKWebView?
    autoreleasepool {
      let view = WKWebView()
      released = view
      cache.store(view, key: "idle", dark: true, height: nil)
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(cache.take(key: "idle") == nil)
    #expect(released == nil)
  }

  @Test func dismantleUnbindsOldCallbacksAndDoesNotCacheFailures() async throws {
    let parent = HTMLRenderWebView(
      html: "<p>cached</p>", dark: true, cacheIdentity: UUID().uuidString,
      onHeight: { _ in }, onError: { _ in }, onLink: { _ in })
    let coordinator = parent.makeCoordinator()
    let view = WKWebView()
    view.configuration.userContentController.add(coordinator, name: "renderEvent")
    view.navigationDelegate = coordinator
    HTMLRenderWebView.dismantleNSView(view, coordinator: coordinator)
    let key = try #require(coordinator.cacheKey)
    let cached = try #require(HTMLRenderWebViewCache.shared.take(key: key))
    #expect(cached.view === view)
    #expect(cached.view.navigationDelegate == nil)
    coordinator.reusable = false
    HTMLRenderWebView.dismantleNSView(view, coordinator: coordinator)
    #expect(HTMLRenderWebViewCache.shared.take(key: key) == nil)
  }
}

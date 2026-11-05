import AppKit
import SwiftUI
import Testing

@testable import PiMacApp

@MainActor
private final class ReadingFixture: ObservableObject {
  @Published var selected = 0
  let ids = [UUID(), UUID()]
  let workspace = WorkspaceModel(restoreUserState: false)
  let models = [
    AppModel(continueLastSession: false), AppModel(continueLastSession: false),
  ]

  init() {
    for (index, model) in models.enumerated() {
      model.currentSessionPath = "t3:reading-\(index)"
      model.messages = (0..<60).flatMap { turn in
        [
          ChatEntry(id: "u\(turn)", kind: .user, title: "你", text: "问题 \(turn)"),
          ChatEntry(
            id: "a\(turn)", kind: .assistant, title: "Pi",
            text: "回答 \(turn)\n\n" + String(repeating: "确定性的历史内容，用于验证阅读位置。\n", count: 4)),
        ]
      }
    }
  }
}

private struct ReadingFixtureView: View {
  @ObservedObject var fixture: ReadingFixture
  var body: some View {
    ContentView(tabID: fixture.ids[fixture.selected])
      .environmentObject(fixture.models[fixture.selected])
      .environmentObject(fixture.workspace)
      .environmentObject(fixture.workspace.extensionUI)
      .frame(width: 1100, height: 800)
      .preferredColorScheme(.dark)
  }
}

@MainActor
struct ConversationReadingPositionTests {
  @Test func switchingConversationsRestoresHistoryAndKeepsBottomFollowing() async throws {
    let fixture = ReadingFixture()
    defer {
      for model in fixture.models { model.disconnect() }
      fixture.workspace.disconnectAll()
    }
    let host = NSHostingView(rootView: ReadingFixtureView(fixture: fixture))
    host.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFrontRegardless()
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    func settle() async throws {
      try await Task.sleep(for: .milliseconds(450))
      host.layoutSubtreeIfNeeded()
    }
    func scrolls(_ view: NSView) -> [NSScrollView] {
      (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
    }
    func transcript() throws -> NSScrollView {
      try #require(scrolls(host).first { ($0.documentView?.bounds.height ?? 0) > 3000 })
    }
    func bottomDistance(_ scroll: NSScrollView) -> CGFloat {
      (scroll.documentView?.bounds.maxY ?? 0) - scroll.contentView.bounds.maxY
    }
    func capture(_ name: String) throws {
      guard let directory = ProcessInfo.processInfo.environment["PIMAC_READING_CAPTURE"] else {
        return
      }
      window.displayIfNeeded()
      // layer-backed AppKit 文本无法由 cacheDisplay 完整绘制，捕获测试窗口的实际合成结果。
      let image = try #require(
        CGWindowListCreateImage(
          .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
          [.boundsIgnoreFraming, .bestResolution]
        ))
      let bitmap = NSBitmapImageRep(cgImage: image)
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
    try await settle()
    let scroll = try transcript()
    #expect(abs(bottomDistance(scroll)) < 3)
    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 1800))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await settle()
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    let origin = scroll.contentView.bounds.origin.y
    #expect(bottomDistance(scroll) > 1000)
    try capture("leaving")
    fixture.selected = 1
    try await settle()
    #expect(abs(bottomDistance(try transcript())) < 3)
    fixture.models[0].messages.append(
      ChatEntry(id: "background-output", kind: .assistant, title: "Pi", text: "离开期间到达的新输出")
    )
    fixture.selected = 0
    try await settle()
    let restored = try transcript()
    #expect(abs(restored.contentView.bounds.origin.y - origin) < 3)
    #expect(bottomDistance(restored) > 1000)
    try capture("returned")
    // 另一会话原先在底部，返回时仍保持跟随，不受历史阅读状态污染。
    fixture.selected = 1
    try await settle()
    #expect(abs(bottomDistance(try transcript())) < 3)
    fixture.selected = 0
    try await Task.sleep(for: .milliseconds(30))
    fixture.selected = 1
    try await Task.sleep(for: .milliseconds(30))
    fixture.selected = 0
    try await settle()
    #expect(abs(try transcript().contentView.bounds.origin.y - origin) < 3)
  }
}

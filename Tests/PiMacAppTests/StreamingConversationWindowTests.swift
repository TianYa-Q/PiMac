import AppKit
import SwiftUI
import Testing

@testable import PiMacApp

@MainActor
private final class StreamingWindowState: ObservableObject {
  @Published var tail = "初始输出"
  @Published var following = false
  var mounted: Set<Int> = []
  var rendered: [Int: String] = [:]
}

private struct StreamingWindowFixture: View {
  @ObservedObject var state: StreamingWindowState

  var body: some View {
    ScrollView {
      VirtualConversationStack(ids: (0..<100).map(String.init), pinnedToBottom: state.following) {
        index in
        let text = index == 99 ? state.tail : "历史消息 \(index)"
        Text(text)
          .frame(maxWidth: .infinity, minHeight: 120)
          .onAppear {
            state.mounted.insert(index)
            state.rendered[index] = text
          }
          .onDisappear { state.mounted.remove(index) }
          .onChange(of: text) { state.rendered[index] = text }
      }
    }
    .frame(width: 700, height: 500)
  }
}

@MainActor
struct StreamingConversationWindowTests {
  @Test func readingHistorySkipsOffscreenOutputAndReturningShowsTheLatestText() async throws {
    let state = StreamingWindowState()
    let host = NSHostingView(rootView: StreamingWindowFixture(state: state))
    host.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    func waitUntil(_ phase: String, _ condition: () -> Bool) async throws {
      for _ in 0..<80 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
        host.layoutSubtreeIfNeeded()
      }
      #expect(condition(), "Timed out waiting for \(phase)")
    }
    func findScroll(_ view: NSView) -> NSScrollView? {
      if let scroll = view as? NSScrollView { return scroll }
      return view.subviews.lazy.compactMap { findScroll($0) }.first
    }
    try await waitUntil("initial viewport") {
      state.mounted.contains(0) && !state.mounted.contains(99)
    }
    let scroll = try #require(findScroll(host))
    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 10_000))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await waitUntil("history window") {
      !state.mounted.contains(0) && !state.mounted.contains(99)
    }
    let origin = scroll.contentView.bounds.origin
    state.tail = String(repeating: "持续输出\n", count: 200) + "最新末尾"
    try await Task.sleep(for: .milliseconds(40))
    host.layoutSubtreeIfNeeded()
    #expect(!state.mounted.contains(99))
    #expect(scroll.contentView.bounds.origin == origin)
    // 不能仅删掉尾部视图：占位必须保留，才能继续滚到最新消息。
    #expect(try #require(scroll.documentView).bounds.height > origin.y + 500)
    state.following = true
    try await waitUntil("following tail") {
      state.mounted.contains(99) && state.rendered[99] == state.tail
    }
    state.following = false
    try await waitUntil("tail recycled") { !state.mounted.contains(99) }
    let height = try #require(scroll.documentView).bounds.height
    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: height - 500))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await waitUntil("return to latest output") {
      state.mounted.contains(99) && state.rendered[99] == state.tail
    }
    #expect(state.rendered[99]?.hasSuffix("最新末尾") == true)
  }
}

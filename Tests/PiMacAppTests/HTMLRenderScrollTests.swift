import AppKit
import Testing
import WebKit

@testable import PiMacApp

@MainActor
struct HTMLRenderScrollTests {
  @Test func fittedPagesAndBoundariesReleaseVerticalWheel() throws {
    let fitted = try #require(HTMLRenderScrollState(top: 0, height: 400, viewport: 400))
    #expect(fitted.routesToConversation(deltaY: 10, deltaX: 0))
    #expect(fitted.routesToConversation(deltaY: -10, deltaX: 0))
    let middle = try #require(HTMLRenderScrollState(top: 200, height: 1000, viewport: 400))
    #expect(!middle.routesToConversation(deltaY: 10, deltaX: 0))
    #expect(!middle.routesToConversation(deltaY: -10, deltaX: 0))
    let top = try #require(HTMLRenderScrollState(top: 0, height: 1000, viewport: 400))
    #expect(top.routesToConversation(deltaY: 10, deltaX: 0))
    #expect(!top.routesToConversation(deltaY: -10, deltaX: 0))
    let bottom = try #require(HTMLRenderScrollState(top: 600, height: 1000, viewport: 400))
    #expect(bottom.routesToConversation(deltaY: -10, deltaX: 0))
    #expect(!bottom.routesToConversation(deltaY: 0, deltaX: 10))
    #expect(!bottom.routesToConversation(deltaY: -1, deltaX: 10))
    #expect(HTMLRenderScrollState(top: .nan, height: 1000, viewport: 400) == nil)
  }

  @Test func mouseWheelUsesLineScaleAndDoesNotStealScrollablePageInput() throws {
    let parent = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    let document = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 2000))
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    document.addSubview(web)
    parent.documentView = document
    let representable = HTMLRenderWebView(
      html: "", dark: true, onHeight: { _ in }, onError: { _ in }, onLink: { _ in })
    let coordinator = HTMLRenderWebView.Coordinator(parent: representable)
    coordinator.observeWheel(in: web)
    defer { coordinator.stopObservingWheel() }
    let cg = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 2, wheel2: 0, wheel3: 0
      ))
    let event = try #require(NSEvent(cgEvent: cg))
    #expect(!event.hasPreciseScrollingDeltas)
    let start = parent.contentView.bounds.origin.y
    #expect(coordinator.routeWheel(event))
    let moved = parent.contentView.bounds.origin.y
    #expect(moved == start + event.scrollingDeltaY * parent.verticalLineScroll)
    coordinator.scrollState = try #require(
      HTMLRenderScrollState(top: 200, height: 1000, viewport: 400))
    #expect(!coordinator.routeWheel(event))
    #expect(parent.contentView.bounds.origin.y == moved)
  }

  @Test func preciseWheelMovesLongNativeTranscriptSynchronously() throws {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 500, height: 2000))
    let web = WKWebView(frame: NSRect(x: 0, y: 400, width: 500, height: 300))
    document.addSubview(web)
    scroll.documentView = document
    let window = NSWindow(
      contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = scroll
    defer { window.contentView = nil }
    scroll.layoutSubtreeIfNeeded()
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
    scroll.reflectScrolledClipView(scroll.contentView)
    let representable = HTMLRenderWebView(
      html: "", dark: true, onHeight: { _ in }, onError: { _ in }, onLink: { _ in })
    let coordinator = HTMLRenderWebView.Coordinator(parent: representable)
    coordinator.observeWheel(in: web)
    defer { coordinator.stopObservingWheel() }
    let start = scroll.contentView.bounds.origin.y
    let cg = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 20, wheel2: 0, wheel3: 0
      ))
    // 精确触控板事件直接提交像素位移，避免无真实窗口归属的粗粒度模拟滚轮走共享动画器。
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    let event = try #require(NSEvent(cgEvent: cg))
    #expect(coordinator.routeWheel(event))
    #expect(scroll.contentView.bounds.origin.y == start - event.scrollingDeltaY)
  }

  private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
  }

}

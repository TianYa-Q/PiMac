import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PiMacApp

@MainActor
struct HTMLRenderImageTests {
  @Test func imageSourcesStayWithinTheSandboxNetworkAndImageDataBoundary() throws {
    for source in [
      "https://example.com/image.png", "http://example.com/image.webp",
      "data:image/png;base64,aGVsbG8=", "data:image/svg+xml,%3Csvg/%3E",
    ] {
      #expect(HTMLRenderImageSource(source)?.source == source)
    }
    for source in [
      "", "file:///tmp/private.png", "javascript:alert(1)", "blob:opaque-image",
      "data:text/html,<script>alert(1)</script>", "data:image/png",
      "https://user:secret@example.com/a.png",
      String(repeating: "x", count: HTMLRenderImageSource.maximumLength + 1),
    ] {
      #expect(HTMLRenderImageSource(source) == nil)
    }
  }

  @Test func imagePreviewEscapesScriptContentAndEnablesNativeMagnification() throws {
    let source = "https://example.com/a.png?text=</script><script>evil()</script>"
    let image = try #require(HTMLRenderImageSource(source))
    #expect(!image.document.contains(source))
    #expect(image.document.contains("\\u003c"))
    let preview = HTMLRenderWebView(
      html: image.document, dark: true, onHeight: { _ in }, onError: { _ in },
      onLink: { _ in }, allowsMagnification: true)
    #expect(preview.allowsMagnification)
  }

  @Test func clickingAnImageInTheLiveSandboxOpensThePreview() async throws {
    let source =
      "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/rV8AAAAASUVORK5CYII="
    let html = """
      <style>html,body{margin:0}img{width:200px;height:160px}</style><img src="\(source)">
      <script>window.addEventListener('load',()=>parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/size-changed',params:{height:160}},'*'));</script>
      """
    var ready = false
    var selected: HTMLRenderImageSource?
    let host = NSHostingView(
      rootView: HTMLRenderWebView(
        html: html, dark: false, onHeight: { _ in ready = true }, onError: { _ in },
        onLink: { _ in }, onImage: { selected = $0 }
      ).frame(width: 300, height: 200))
    host.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    host.layoutSubtreeIfNeeded()
    for _ in 0..<100 where !ready { try await Task.sleep(for: .milliseconds(50)) }
    #expect(ready)
    // 原生鼠标事件在 WebKit 中保留 isTrusted，覆盖真正点击而不是页面脚本伪造 click。
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try #require(
        NSEvent.mouseEvent(
          with: type, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
          pressure: 1))
      window.sendEvent(event)
    }
    for _ in 0..<100 where selected == nil { try await Task.sleep(for: .milliseconds(50)) }
    #expect(selected?.source == source)
  }

  @Test func pageScrollingIsContainedAndImagesHaveAClickBridge() {
    let wrapper = HTMLRenderWebView.document(
      html: "<img src='https://example.com/a.png'>", dark: true)
    #expect(wrapper.contains("overscroll-behavior:contain"))
    #expect(!wrapper.contains("pi/scroll-state"))
    #expect(wrapper.contains("pi/open-image"))
    #expect(wrapper.contains("e.isTrusted"))
    #expect(wrapper.contains("HTMLImageElement"))
    #expect(wrapper.contains("e.source!==page.contentWindow"))
    #expect(wrapper.contains("sandbox=\"allow-scripts\""))
    #expect(!wrapper.contains("allow-same-origin"))
  }
}

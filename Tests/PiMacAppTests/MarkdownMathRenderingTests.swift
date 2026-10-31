import AppKit
import SwiftUI
import Testing
import WebKit

@testable import PiMacApp

@MainActor
struct MarkdownMathRenderingTests {
  @Test func offlineTypesettingFallbackAndStreamingReuse() async throws {
    let host = NSHostingView(
      rootView: MarkdownView(#"分数 \(\frac{1}{2}\)，**变量 $x$**。\(\unsupported{x}\)"#))
    host.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    func webView(in view: NSView) -> WKWebView? {
      if let web = view as? WKWebView { return web }
      return view.subviews.lazy.compactMap { webView(in: $0) }.first
    }
    host.layoutSubtreeIfNeeded()
    let web = try #require(webView(in: host))
    func waitFor(_ script: String) async throws {
      for _ in 0..<100 {
        if (try? await web.evaluateJavaScript(script)) as? Bool == true { return }
        try await Task.sleep(for: .milliseconds(50))
      }
      Issue.record("WebKit did not reach expected rendering state: \(script)")
    }
    try await waitFor("window.mathReady && document.querySelectorAll('.katex').length === 2")
    let loadedFonts = try await web.evaluateJavaScript("document.fonts.check('16px KaTeX_Main')")
    #expect(loadedFonts as? Bool == true)
    let error = try await web.evaluateJavaScript(
      "document.querySelector('.math-error').textContent")
    #expect(error as? String == #"\(\unsupported{x}\)"#)
    let strong = try await web.evaluateJavaScript(
      "document.querySelector('strong .katex') !== null")
    #expect(strong as? Bool == true)
    // 普通文字保持可选、可复制；数学使用 MathML 提供辅助功能语义。
    let selection = try await web.evaluateJavaScript(
      "const r=document.createRange();r.selectNodeContents(document.getElementById('content'));window.getSelection().removeAllRanges();window.getSelection().addRange(r);window.getSelection().toString()"
    )
    #expect((selection as? String)?.contains("分数") == true)
    for _ in 0..<20 {
      if web.accessibilitySelectedText()?.contains("分数") == true { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(web.accessibilitySelectedText()?.contains("分数") == true)
    let mathML = try await web.evaluateJavaScript("document.querySelectorAll('math').length")
    #expect(mathML as? Int == 2)
    _ = try await web.evaluateJavaScript("window.reuseMarker = true")
    host.rootView = MarkdownView(#"已更新 \(x^2+1\)"#)
    host.layoutSubtreeIfNeeded()
    try await waitFor("window.mathReady && document.body.textContent.includes('已更新')")
    #expect(webView(in: host) === web)
    let reused = try await web.evaluateJavaScript("window.reuseMarker")
    #expect(reused as? Bool == true)
    let rendered = try await web.evaluateJavaScript("document.querySelectorAll('.katex').length")
    #expect(rendered as? Int == 1)
    let height = try await web.evaluateJavaScript("document.body.getBoundingClientRect().height")
    #expect((height as? Double ?? 0) > 10)
  }
}

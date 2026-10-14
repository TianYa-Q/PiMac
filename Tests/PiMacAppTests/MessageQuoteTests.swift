import AppKit
import SwiftUI
import Testing
@testable import PiMacApp

struct MessageQuoteTests {
  @Test func multilineQuoteAndCursor() throws {
    let result = try #require(MessageQuote.inserting(
      "第一步\r\n\n第二步😀", into: "回复", selection: NSRange(location: 2, length: 0)))
    #expect(result.text == "回复\n\n> 第一步\n> \n> 第二步😀\n\n")
    #expect(result.selection == NSRange(location: result.text.utf16.count, length: 0))
    #expect(AppModel.makePrompt(result.text, attachments: [], delivery: .followUp)?.rpcText
      == result.text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  @Test func replacesSelectionAndRejectsEmptyQuote() throws {
    let result = try #require(MessageQuote.inserting(
      "片段", into: "删除剩余", selection: NSRange(location: 0, length: 2)))
    #expect(result.text == "> 片段\n\n剩余")
    #expect(MessageQuote.inserting(" \n", into: "草稿", selection: NSRange(location: 0, length: 0)) == nil)
    let stale = try #require(MessageQuote.inserting(
      "新引用", into: "", selection: NSRange(location: NSNotFound, length: 90)))
    #expect(stale.text == "> 新引用\n\n")
  }

  @MainActor @Test func readsNativeSwiftUISelectionWithoutClipboardChanges() async throws {
    var selected = ""
    let host = NSHostingView(rootView:
      VStack(spacing: 24) {
        MarkdownView("第一段文字\n\n第二段文字")
          .background { MessageSelectionReader { selected = $0 } }
        Text("其他消息").textSelection(.enabled)
      }
      .frame(width: 400, height: 160))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap { descendants($0) }
    }
    let views = descendants(host)
    let textView = try #require(views.first {
      ($0.accessibilityValue() as? String)?.contains("第一段文字") == true
        && $0.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilitySelectedTextRange:"))
    })
    let clipboardRevision = NSPasteboard.general.changeCount
    textView.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 3))
    let anchor = try #require(views.compactMap { $0 as? MessageSelectionReader.SelectionAnchor }.first)
    anchor.refreshSelection()
    #expect(selected == "第一段")
    #expect(NSPasteboard.general.changeCount == clipboardRevision)
    textView.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 0))
    anchor.refreshSelection()
    #expect(selected.isEmpty)
    let otherView = try #require(views.first {
      ($0.accessibilityValue() as? String) == "其他消息"
        && $0.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilitySelectedTextRange:"))
    })
    otherView.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 4))
    anchor.refreshSelection()
    #expect(selected.isEmpty)
  }
}

import AppKit
import Testing

@testable import PiMacApp

struct MessageQuoteTests {
  @Test func multilineQuoteAndCursor() throws {
    let result = try #require(
      MessageQuote.inserting(
        "第一步\r\n\n第二步😀", into: "回复", selection: NSRange(location: 2, length: 0)))
    #expect(result.text == "回复\n\n> 第一步\n> \n> 第二步😀\n\n")
    #expect(result.selection == NSRange(location: result.text.utf16.count, length: 0))
    #expect(
      AppModel.makePrompt(result.text, attachments: [], delivery: .followUp)?.rpcText
        == result.text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  @Test func replacesSelectionAndRejectsEmptyQuote() throws {
    let result = try #require(
      MessageQuote.inserting(
        "片段", into: "删除剩余", selection: NSRange(location: 0, length: 2)))
    #expect(result.text == "> 片段\n\n剩余")
    #expect(
      MessageQuote.inserting(" \n", into: "草稿", selection: NSRange(location: 0, length: 0)) == nil)
    let stale = try #require(
      MessageQuote.inserting(
        "新引用", into: "", selection: NSRange(location: NSNotFound, length: 90)))
    #expect(stale.text == "> 新引用\n\n")
  }

  @MainActor @Test func readsNativeSelectionWithoutClipboardChanges() throws {
    var selected = ""
    // 用公开的 NSTextView 提供真实 AX 选区，避免依赖不同 macOS 的 SwiftUI 私有子视图结构。
    // 本测试验证选区读取器的归属和剪贴板边界，不冒充 SwiftUI 手势端到端验收。
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 160))
    let textView = NSTextView(frame: NSRect(x: 0, y: 80, width: 400, height: 80))
    textView.string = "第一段文字\n\n第二段文字"
    textView.isEditable = false
    textView.isSelectable = true
    let otherView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
    otherView.string = "其他消息"
    otherView.isEditable = false
    otherView.isSelectable = true
    let anchor = MessageSelectionReader.SelectionAnchor { selected = $0 }
    anchor.frame = textView.frame
    host.addSubview(textView)
    host.addSubview(otherView)
    host.addSubview(anchor)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    host.layoutSubtreeIfNeeded()
    let clipboardRevision = NSPasteboard.general.changeCount
    textView.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 3))
    anchor.refreshSelection()
    #expect(selected == "第一段")
    #expect(NSPasteboard.general.changeCount == clipboardRevision)
    textView.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 0))
    anchor.refreshSelection()
    #expect(selected.isEmpty)
    otherView.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 4))
    anchor.refreshSelection()
    #expect(selected.isEmpty)
  }
}

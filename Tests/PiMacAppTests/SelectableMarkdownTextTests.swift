import AppKit
import SwiftUI
import Testing

@testable import PiMacApp

@MainActor
struct SelectableMarkdownTextTests {
  private let source = """
    # 标题

    正文包含 **粗体**、*斜体*、~~删除线~~、`code` 和 [链接](https://example.com)。

    1. 第一项中文长文本，需要在窄窗口中正确换行，不隐藏末尾内容。
    2. 第二项。

    ```swift
    let value = "**literal**"
    ```

    最后一段必须完整显示。
    """

  @Test func richTextPreservesStylesLinksAndLiteralCode() throws {
    let text = MarkdownTextContent.attributedString(
      blocks: MarkdownDocument(source).blocks, textStyle: .body)
    func attributes(_ substring: String) throws -> [NSAttributedString.Key: Any] {
      let range = (text.string as NSString).range(of: substring)
      #expect(range.location != NSNotFound)
      return text.attributes(at: range.location, effectiveRange: nil)
    }
    let heading = try #require(try attributes("标题")[.font] as? NSFont)
    let bold = try #require(try attributes("粗体")[.font] as? NSFont)
    let italic = try #require(try attributes("斜体")[.font] as? NSFont)
    let code = try #require(try attributes("code")[.font] as? NSFont)
    #expect(heading.pointSize > bold.pointSize)
    #expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
    #expect(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
    #expect(code.isFixedPitch)
    #expect(try attributes("删除线")[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
    #expect(try attributes("链接")[.link] as? URL == URL(string: "https://example.com"))
    #expect(text.string.contains("let value = \"**literal**\""))
    #expect(text.string.hasSuffix("最后一段必须完整显示。"))
  }

  @Test func widthProbesDoNotChangeDrawingOrSelectionAndContentCanGrowAndShrink() throws {
    let view = MarkdownTextView()
    let content = MarkdownTextContent.attributedString(
      blocks: MarkdownDocument(source).blocks, textStyle: .body)
    view.setText(content)
    let size = view.measuredSize(width: 600)
    view.setFrameSize(size)
    let selection = (view.string as NSString).range(of: "粗体")
    view.setSelectedRange(selection)
    let narrow = view.measuredSize(width: 180)
    #expect(narrow.height > size.height)
    #expect(view.textContainer?.containerSize.width == view.bounds.width)
    #expect(view.selectedRange() == selection)
    #expect(view.measuredSize(width: 600) == size)
    view.setText(content)
    #expect(view.selectedRange() == selection)
    let longer = MarkdownTextContent.attributedString(
      blocks: MarkdownDocument(source + "\n\n" + source).blocks, textStyle: .body)
    view.setText(longer)
    #expect(view.measuredSize(width: 600).height > size.height)
    view.setText(
      NSAttributedString(string: "短文本", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
    #expect(view.measuredSize(width: 600).height < size.height)
  }

  @Test func repeatedWidthProbesReuseLayoutAndInvalidateForNewContentAndFont() throws {
    final class LayoutCounter: NSObject, NSLayoutManagerDelegate {
      var completions = 0
      func layoutManager(
        _ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?,
        atEnd layoutFinishedFlag: Bool
      ) {
        completions += 1
      }
    }
    let view = MarkdownTextView()
    let blocks = MarkdownDocument(source).blocks
    view.setContent(blocks: blocks, textStyle: .body)
    view.setFrameSize(view.measuredSize(width: 600))
    let counter = LayoutCounter()
    view.layoutManager?.delegate = counter
    let widths: [CGFloat] = [600, 200, 800]
    let sizes = widths.map { view.measuredSize(width: $0) }
    let warmedCompletions = counter.completions
    for _ in 0..<20 {
      view.setContent(blocks: blocks, textStyle: .body)
      #expect(widths.map { view.measuredSize(width: $0) } == sizes)
    }
    #expect(counter.completions == warmedCompletions)
    #expect(view.textContainer?.containerSize.width == 600)
    view.setContent(blocks: blocks, textStyle: .title1)
    #expect(view.measuredSize(width: 600).height > sizes[0].height)
    #expect(counter.completions > warmedCompletions)
    view.setContent(blocks: MarkdownDocument("短文本").blocks, textStyle: .body)
    #expect(view.measuredSize(width: 600).height < sizes[0].height)
  }

  @Test func hostedReplyKeepsItsHeightAndQuoteSelectionWhenFocused() async throws {
    let host = NSHostingView(
      rootView: MarkdownView(source).frame(width: 600).fixedSize(horizontal: false, vertical: true))
    host.setFrameSize(host.fittingSize)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    func findText(_ view: NSView) -> MarkdownTextView? {
      if let text = view as? MarkdownTextView { return text }
      return view.subviews.lazy.compactMap { findText($0) }.first
    }
    let view = try #require(findText(host))
    let before = view.frame
    #expect(before.width == 600)
    #expect(!view.isEditable && view.isSelectable)
    #expect(window.makeFirstResponder(view))
    let selection = (view.string as NSString).range(of: "最后一段必须完整显示。")
    view.setSelectedRange(selection)
    host.layoutSubtreeIfNeeded()
    #expect(view.accessibilitySelectedText() == "最后一段必须完整显示。")
    #expect(view.frame == before)
    #expect(view.textContainer?.containerSize.width == before.width)
    let manager = try #require(view.layoutManager)
    let container = try #require(view.textContainer)
    manager.ensureLayout(for: container)
    #expect(manager.usedRect(for: container).maxY <= before.height)
    #expect(view.measuredSize(width: 600).height == before.height)
  }
}

import AppKit
import Testing

@testable import PiMacApp

struct ToolOutputPresentationTests {
  @Test func boundsBytesWithoutSplittingUnicodeScalars() {
    let preview = ToolOutputPresentation(text: "a😀中z", maximumBytes: 6)
    #expect(preview.text == "a😀")
    #expect(preview.isTruncated)
    #expect(preview.text.utf8.count <= 6)
    #expect(!ToolOutputPresentation(text: "😀", maximumBytes: 4).isTruncated)
  }

  @Test func boundsLinesIncludingEmptyLines() {
    let preview = ToolOutputPresentation(text: "a\n\nb\nc", maximumLines: 3)
    #expect(preview.text == "a\n\nb")
    #expect(preview.lineCount == 3)
    #expect(preview.isTruncated)
    #expect(ToolOutputPresentation(text: "").lineCount == 1)
    #expect(!ToolOutputPresentation(text: "a\nb", maximumLines: 2).isTruncated)
  }

  @Test func nativeLineSeparatorsCannotBypassRowLimit() {
    for separator in ["\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"] {
      let preview = ToolOutputPresentation(text: "a\(separator)b\(separator)c", maximumLines: 2)
      #expect(preview.text == "a\(separator)b")
      #expect(preview.lineCount == 2)
      #expect(preview.isTruncated)
    }
  }

  @MainActor @Test func wrappedHeightIsAvailableBeforeWindowAttachment() {
    let view = ToolOutputScrollView()
    view.setWrapsLines(true)
    view.setOutput(String(repeating: "long output ", count: 60))
    view.prepareLayout(viewportWidth: 240)
    let narrowHeight = view.outputSize.height
    #expect(view.outputSize.width <= 240)
    view.prepareLayout(viewportWidth: 480)
    #expect(view.outputSize.height < narrowHeight)
  }

  @Test func hugeOutputHasBoundedLayoutInput() {
    let preview = ToolOutputPresentation(text: String(repeating: "😀\n", count: 100_000))
    #expect(preview.lineCount == ToolOutputPresentation.maximumLines)
    #expect(preview.text.utf8.count <= ToolOutputPresentation.maximumBytes)
    #expect(preview.isTruncated)
  }

  @Test func searchIsLiteralCaseInsensitiveAndUsesNativeRanges() {
    let preview = ToolOutputPresentation(text: "😀 ABC abc [x] ababa")
    #expect(
      preview.matches(for: "abc") == [
        NSRange(location: 3, length: 3), NSRange(location: 7, length: 3),
      ])
    #expect(preview.matches(for: "[x]") == [NSRange(location: 11, length: 3)])
    #expect(preview.matches(for: "aba").count == 1)
    #expect(preview.matches(for: "").isEmpty)
    #expect(preview.matches(for: "missing").isEmpty)
    #expect(
      ToolOutputPresentation(text: String(repeating: "x", count: 2000)).matches(for: "x").count
        == 1000)
  }

  @MainActor @Test func nativeWrapRelayoutsWhenViewportChanges() {
    let view = ToolOutputScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 240, height: 200)
    view.setOutput(String(repeating: "long output ", count: 60))
    view.layout()
    let unwrapped = view.outputSize
    view.setWrapsLines(true)
    view.layout()
    #expect(!view.hasHorizontalScroller)
    #expect(view.outputSize.height > unwrapped.height)
    #expect(view.outputSize.width <= 240)
    let narrowHeight = view.outputSize.height
    view.frame.size.width = 480
    view.layout()
    #expect(view.outputSize.height < narrowHeight)
    view.setWrapsLines(false)
    view.layout()
    #expect(view.hasHorizontalScroller)
    #expect(view.outputSize == unwrapped, "restored \(view.outputSize), original \(unwrapped)")
  }

  @MainActor @Test func nativeSearchRejectsOverflowAndNegativeRanges() {
    let view = ToolOutputScrollView()
    view.setOutput("hello")
    let valid = NSRange(location: 1, length: 2)
    view.setSearchSelection(valid)
    for invalid in [
      NSRange(location: Int.max - 1, length: 10),
      NSRange(location: -1, length: 1),
      NSRange(location: 1, length: -1),
    ] {
      view.setSearchSelection(invalid)
      #expect(view.outputTextView.selectedRange() == valid)
    }
  }

  @MainActor @Test func nativeSearchPreservesSelectionUntilNavigation() {
    let view = ToolOutputScrollView()
    view.setOutput("😀 first second")
    let range = NSRange(location: 3, length: 5)
    view.setSearchSelection(range)
    #expect(view.outputTextView.selectedRange() == range)
    view.outputTextView.setSelectedRange(NSRange(location: 0, length: 2))
    view.setSearchSelection(range)
    #expect(view.outputTextView.selectedRange() == NSRange(location: 0, length: 2))
    view.setSearchSelection(nil)
    view.setSearchSelection(range)
    #expect(view.outputTextView.selectedRange() == range)
    view.setSearchSelection(NSRange(location: 100, length: 5))
    #expect(view.outputTextView.selectedRange() == range)
  }
}

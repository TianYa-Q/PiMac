import AppKit
import Testing

@testable import PiMacApp

@MainActor
struct ToolOutputViewTests {
  @Test func allMatchesUseTemporaryAttributesWithoutChangingTextOrSelection() {
    let view = ToolOutputScrollView()
    view.setOutput("cat cat")
    let selection = NSRange(location: 0, length: 3)
    view.outputTextView.setSelectedRange(selection)
    view.setSearchMatches([selection, NSRange(location: 4, length: 3)])
    #expect(view.searchMatches.count == 2)
    #expect(view.outputTextView.selectedRange() == selection)
    #expect(view.outputTextView.string == "cat cat")
    let manager = view.outputTextView.layoutManager!
    #expect(
      manager.temporaryAttribute(.backgroundColor, atCharacterIndex: 4, effectiveRange: nil) != nil)
    #expect(
      view.outputTextView.textStorage!.attribute(.backgroundColor, at: 4, effectiveRange: nil)
        == nil)
    view.setSearchMatches([])
    #expect(
      manager.temporaryAttribute(.backgroundColor, atCharacterIndex: 4, effectiveRange: nil) == nil)
    view.setSearchMatches([selection])
    view.setOutput("dog dog")
    view.setSearchMatches([])
    #expect(
      manager.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil)
  }

  @Test func invalidAndExcessiveHighlightsAreBoundedAndReplacementClearsOldRanges() {
    let view = ToolOutputScrollView()
    view.setOutput("cat cat")
    view.setSearchMatches([
      NSRange(location: Int.max, length: Int.max), NSRange(location: -1, length: 1),
      NSRange(location: 6, length: 2), NSRange(location: 0, length: 0),
      NSRange(location: 4, length: 3),
    ])
    #expect(view.searchMatches == [NSRange(location: 4, length: 3)])
    view.setSearchMatches(Array(repeating: NSRange(location: 0, length: 3), count: 2000))
    #expect(view.searchMatches.count == ToolOutputPresentation.maximumMatches)
    view.setOutput("x")
    view.setSearchMatches([NSRange(location: 4, length: 3)])
    #expect(view.searchMatches.isEmpty)
  }

  @Test func tailFollowingScrollsAfterLayoutAndCanBePaused() {
    let view = ToolOutputScrollView()
    view.setFrameSize(CGSize(width: 300, height: 100))
    view.setOutput(Array(repeating: "line", count: 100).joined(separator: "\n"))
    view.setFollowsTail(true)
    view.layoutSubtreeIfNeeded()
    #expect(view.contentView.bounds.maxY >= view.outputTextView.frame.height - 1)
    view.setFollowsTail(false)
    view.contentView.scroll(to: .zero)
    view.setOutput(Array(repeating: "line", count: 120).joined(separator: "\n"))
    view.layoutSubtreeIfNeeded()
    #expect(view.contentView.bounds.origin.y == 0)
  }

  @Test func outputIsLaidOutBeforeAnyClickOrWindowAttachment() {
    let view = ToolOutputScrollView()
    view.setOutput("Script completed\nWall time 0.1 seconds\nOutput:\n\nimport Foundation")
    #expect(view.outputTextView.string.contains("import Foundation"))
    #expect(view.outputSize.height > 60)
    #expect(view.outputTextView.layoutManager!.numberOfGlyphs > 0)
    #expect(view.outputTextView.frame.height >= view.outputSize.height)
    #expect(view.outputTextView.isSelectable)
    #expect(!view.outputTextView.isEditable)
  }

  @Test func streamingUpdatesRefreshLayoutWithoutRecreatingTheView() {
    let view = ToolOutputScrollView()
    view.setOutput("first")
    let initial = view.outputSize
    view.outputTextView.setSelectedRange(NSRange(location: 0, length: 5))
    view.setOutput("first\n" + Array(repeating: "more output", count: 100).joined(separator: "\n"))
    #expect(view.outputSize.height > 300)
    #expect(view.outputSize.height > initial.height)
    #expect(view.outputTextView.selectedRange() == NSRange(location: 0, length: 5))
    view.setOutput("x")
    #expect(view.outputSize.height == initial.height)
    #expect(view.outputTextView.selectedRange() == NSRange(location: 0, length: 1))
  }

  @Test func replacementReappliesSameSearchRangeWithoutStealingManualSelectionOnOtherUpdates() {
    let view = ToolOutputScrollView()
    let match = NSRange(location: 4, length: 3)
    view.setOutput("one cat")
    view.setSearchSelection(match)
    view.outputTextView.setSelectedRange(NSRange(location: 0, length: 3))
    view.setSearchSelection(match)
    #expect(view.outputTextView.selectedRange().location == 0)
    view.setOutput("two cat")
    view.setSearchSelection(match)
    #expect(view.outputTextView.selectedRange() == match)
    view.setOutput("x")
    view.setSearchSelection(match)
    #expect(view.outputTextView.selectedRange() == NSRange(location: 1, length: 0))
  }

  @Test func clearingSearchCollapsesOnlySearchOwnedSelection() {
    let view = ToolOutputScrollView()
    view.setOutput("one cat")
    let match = NSRange(location: 4, length: 3)
    view.setSearchSelection(match)
    view.setSearchSelection(nil)
    #expect(view.outputTextView.selectedRange() == NSRange(location: 4, length: 0))
    view.setSearchSelection(match)
    let manual = NSRange(location: 0, length: 3)
    view.outputTextView.setSelectedRange(manual)
    view.setSearchSelection(nil)
    #expect(view.outputTextView.selectedRange() == manual)
  }

  @Test func longLinesRemainHorizontallyScrollableAfterResize() {
    let view = ToolOutputScrollView()
    view.setFrameSize(CGSize(width: 300, height: 100))
    view.setOutput(String(repeating: "wide output ", count: 100))
    view.layoutSubtreeIfNeeded()
    #expect(view.outputSize.width > 300)
    #expect(view.outputTextView.frame.width >= view.outputSize.width)
    #expect(view.outputSize.height < 100)
    view.setFrameSize(CGSize(width: 600, height: 100))
    view.layoutSubtreeIfNeeded()
    #expect(view.outputTextView.frame.width >= view.outputSize.width)
  }
}

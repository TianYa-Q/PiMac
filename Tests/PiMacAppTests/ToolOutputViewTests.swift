import AppKit
import Testing

@testable import PiMacApp

@MainActor
struct ToolOutputViewTests {
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

import Foundation
import Testing

@testable import PiMacApp

struct ConversationWindowLayoutTests {
  @Test func emptyTranscriptHasNoWindow() {
    let layout = ConversationWindowLayout(ids: [], heights: [:])
    #expect(layout.height == 0)
    #expect(layout.window(viewport: nil).isEmpty)
  }

  @Test func longTranscriptOnlyMountsASmallWindow() {
    let ids = (0..<10_000).map(String.init)
    let layout = ConversationWindowLayout(ids: ids, heights: [:])
    let initial = layout.window(viewport: nil)
    #expect(initial.contains(9_999))
    #expect(initial.count < 20)
    let middle = layout.window(viewport: CGRect(x: 0, y: 1_500_000, width: 800, height: 900))
    #expect(middle.contains(layout.index(at: 1_500_000)))
    #expect(middle.contains(layout.index(at: 1_500_900)))
    #expect(middle.count < 20)
  }

  @Test func measuredHeightsDetermineOffsetsIncludingSpacing() {
    let layout = ConversationWindowLayout(
      ids: ["a", "b", "c"], heights: ["a": 80, "c": 900], estimate: 200, spacing: 14
    )
    #expect(layout.offsets == [0, 94, 308, 1222])
    #expect(layout.index(at: 93) == 0)
    #expect(layout.index(at: 94) == 1)
    #expect(layout.index(at: 308) == 2)
    #expect(layout.index(at: -100) == 0)
    #expect(layout.index(at: 100_000) == 2)
  }

  @Test func correctingEarlierRowsPreservesTheVisibleAnchor() {
    let ids = ["a", "b", "c", "d"]
    let before = ConversationWindowLayout(ids: ids, heights: [:], estimate: 200)
    let after = ConversationWindowLayout(ids: ids, heights: ["a": 500, "b": 100], estimate: 200)
    let y = before.offsets[2] + 75
    let delta = before.anchorCorrection(to: after, viewportY: y)
    #expect(delta == 200)
    #expect(y + delta - after.offsets[2] == 75)
  }

  @Test func changesToCurrentAndLaterRowsDoNotMoveReadingPosition() {
    let ids = ["a", "b", "c"]
    let before = ConversationWindowLayout(ids: ids, heights: [:])
    let after = ConversationWindowLayout(ids: ids, heights: ["b": 1000, "c": 2000])
    #expect(before.anchorCorrection(to: after, viewportY: before.offsets[1] + 20) == 0)
  }

  @Test func aVeryTallTurnIsIncludedWhenItsTopIsOffscreen() {
    let layout = ConversationWindowLayout(ids: ["a", "b", "c"], heights: ["b": 20_000])
    let range = layout.window(viewport: CGRect(x: 0, y: 10_000, width: 800, height: 800))
    #expect(range == 1..<2)
  }

  @Test func windowIsClampedDuringOverscrollAndResize() {
    let layout = ConversationWindowLayout(ids: ["a", "b"], heights: [:])
    #expect(layout.window(viewport: CGRect(x: 0, y: -500, width: 800, height: 2000)) == 0..<2)
    #expect(layout.window(viewport: CGRect(x: 0, y: 100_000, width: 800, height: 900)) == 1..<2)
  }
}

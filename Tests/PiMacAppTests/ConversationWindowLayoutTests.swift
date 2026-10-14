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

  @Test func pixelScrollingOnlyPublishesWindowTransitions() {
    let layout = ConversationWindowLayout(ids: (0..<10_000).map(String.init), heights: [:])
    var published = CGRect(x: 0, y: 1_500_000, width: 800, height: 900)
    var updates = 0
    for delta in 1...1000 {
      let current = CGRect(x: 0, y: 1_500_000 + delta, width: 800, height: 900)
      if layout.requiresWindowUpdate(from: published, to: current) {
        published = current
        updates += 1
      }
      // 未发布的像素移动不能漏掉任何需要挂载的消息。
      let mounted = layout.window(viewport: published)
      #expect(mounted.contains(layout.index(at: current.minY)))
      #expect(mounted.contains(layout.index(at: current.maxY)))
    }
    #expect(updates > 0)
    #expect(updates < 10)
  }

  @Test func rowBoundaryJitterStaysInsideThePrefetchedWindow() {
    let layout = ConversationWindowLayout(ids: (0..<1000).map(String.init), heights: [:])
    let previous = CGRect(x: 0, y: 10_000, width: 800, height: 900)
    for delta in [-100, -1, 1, 100] {
      #expect(!layout.requiresWindowUpdate(from: previous, to: previous.offsetBy(dx: 0, dy: CGFloat(delta))))
    }
    #expect(layout.requiresWindowUpdate(from: previous, to: previous.offsetBy(dx: 0, dy: 2000)))
  }

  @Test func viewportInitializationResizeAndLargeJumpsAlwaysPublish() {
    let layout = ConversationWindowLayout(ids: (0..<100).map(String.init), heights: [:])
    let rect = CGRect(x: 0, y: 4000, width: 800, height: 900)
    #expect(layout.requiresWindowUpdate(from: nil, to: rect))
    #expect(!layout.requiresWindowUpdate(from: rect, to: rect))
    #expect(layout.requiresWindowUpdate(from: rect, to: rect.offsetBy(dx: 0, dy: 10_000)))
    var resized = rect
    resized.size.width = 600
    #expect(layout.window(viewport: rect) == layout.window(viewport: resized))
    #expect(layout.requiresWindowUpdate(from: rect, to: resized))
    resized = rect
    resized.size.height += 1
    #expect(layout.requiresWindowUpdate(from: rect, to: resized))
  }

  @Test func scrollingInsideTallTurnDoesNotRebuildMessageViews() {
    let layout = ConversationWindowLayout(ids: ["a", "b", "c"], heights: ["b": 20_000])
    let before = CGRect(x: 0, y: 10_000, width: 800, height: 800)
    let after = before.offsetBy(dx: 0, dy: 2000)
    #expect(!layout.requiresWindowUpdate(from: before, to: after))
    let updated = ConversationWindowLayout(ids: ["a", "b", "c"], heights: ["a": 500, "b": 20_000])
    let correction = layout.anchorCorrection(to: updated, viewportY: after.minY)
    #expect(after.minY + correction - updated.offsets[1] == after.minY - layout.offsets[1])
  }

  @Test func windowIsClampedDuringOverscrollAndResize() {
    let layout = ConversationWindowLayout(ids: ["a", "b"], heights: [:])
    #expect(layout.window(viewport: CGRect(x: 0, y: -500, width: 800, height: 2000)) == 0..<2)
    #expect(layout.window(viewport: CGRect(x: 0, y: 100_000, width: 800, height: 900)) == 1..<2)
  }
}

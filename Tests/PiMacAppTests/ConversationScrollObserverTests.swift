import AppKit
import SwiftUI
import Testing

@testable import PiMacApp

@MainActor
struct ConversationScrollObserverTests {
  private final class Document: NSView {
    let usesFlippedCoordinates: Bool
    init(flipped: Bool, height: CGFloat) {
      self.usesFlippedCoordinates = flipped
      super.init(frame: NSRect(x: 0, y: 0, width: 300, height: height))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { usesFlippedCoordinates }
  }

  private func makeScroll(flipped: Bool) -> NSScrollView {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    scroll.documentView = Document(flipped: flipped, height: 1000)
    scroll.layoutSubtreeIfNeeded()
    moveToBottom(scroll)
    return scroll
  }

  private func moveToBottom(_ scroll: NSScrollView) {
    let y = scroll.contentView.isFlipped
      ? max(0, scroll.documentView!.bounds.maxY - scroll.contentView.bounds.height) : 0
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  @Test(arguments: [true, false])
  func downwardBoundaryInputNeverLeavesFollowing(flipped: Bool) {
    let scroll = makeScroll(flipped: flipped)
    var reports: [(Bool, Bool)] = []
    let observer = ConversationScrollObserver.Coordinator(onBottomVisibilityChange: { _ in }) {
      reports.append(($0, $1))
    }
    observer.attach(to: scroll)
    let origin = scroll.contentView.bounds.origin
    for _ in 0..<100 {
      observer.handleScrollWheel(scrollingDeltaY: -5)
      NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
      NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
      NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }
    #expect(!reports.isEmpty)
    #expect(reports.allSatisfy { $0.0 })
    #expect(reports.filter { $0.1 }.count == 100)
    #expect(scroll.contentView.bounds.origin == origin)
  }

  @Test(arguments: [true, false])
  func upwardInputCancelsBeforeMovementAndStartDoesNotRepin(flipped: Bool) {
    let scroll = makeScroll(flipped: flipped)
    var reports: [(Bool, Bool)] = []
    let observer = ConversationScrollObserver.Coordinator(onBottomVisibilityChange: { _ in }) {
      reports.append(($0, $1))
    }
    observer.attach(to: scroll)
    observer.handleScrollWheel(scrollingDeltaY: 5)
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    #expect(reports.count == 1)
    #expect(reports.first?.0 == false)
    #expect(reports.first?.1 == true)

    var origin = scroll.contentView.bounds.origin
    origin.y += scroll.contentView.isFlipped ? -100 : 100
    scroll.contentView.scroll(to: origin)
    observer.handleScrollWheel(scrollingDeltaY: -5)
    #expect(reports.last?.0 == false)
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    #expect(reports.last?.0 == false)

    moveToBottom(scroll)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    #expect(reports.last?.0 == true)
    #expect(reports.last?.1 == false)
  }

  @Test(arguments: [true, false])
  func fractionalBottomRoundingDoesNotPauseFollowing(flipped: Bool) {
    let scroll = makeScroll(flipped: flipped)
    var origin = scroll.contentView.bounds.origin
    origin.y += scroll.contentView.isFlipped ? -1.5 : 1.5
    scroll.contentView.scroll(to: origin)
    var reports: [Bool] = []
    let observer = ConversationScrollObserver.Coordinator(onBottomVisibilityChange: { _ in }) {
      bottom, _ in reports.append(bottom)
    }
    observer.attach(to: scroll)
    observer.handleScrollWheel(scrollingDeltaY: -0.1)
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    #expect(reports == [true, true])
  }

  @Test(arguments: [true, false])
  func actualMovementWorksWithoutDidLiveScroll(flipped: Bool) {
    let scroll = makeScroll(flipped: flipped)
    var visibility: [Bool] = []
    var reports: [(Bool, Bool)] = []
    let observer = ConversationScrollObserver.Coordinator(onBottomVisibilityChange: {
      visibility.append($0)
    }) { reports.append(($0, $1)) }
    observer.attach(to: scroll)
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    var origin = scroll.contentView.bounds.origin
    origin.y += scroll.contentView.isFlipped ? -120 : 120
    scroll.contentView.scroll(to: origin)
    observer.reportPosition()
    #expect(visibility == [true, false])
    #expect(reports.last?.0 == false)
    #expect(reports.last?.1 == true)
    for _ in 0..<100 { observer.reportPosition() }
    #expect(visibility.count == 2)
    #expect(reports.count == 1)
    moveToBottom(scroll)
    observer.reportPosition()
    #expect(visibility == [true, false, true])
    #expect(reports.last?.0 == true)
  }

  @Test func wheelIntentCannotBeUndoneByAnUnmovedBottomReport() {
    let scroll = makeScroll(flipped: true)
    var reports: [Bool] = []
    let observer = ConversationScrollObserver.Coordinator(onBottomVisibilityChange: { _ in }) {
      bottom, _ in reports.append(bottom)
    }
    observer.attach(to: scroll)
    observer.handleScrollWheel(scrollingDeltaY: 5)
    observer.reportPosition()
    #expect(reports == [false])
  }

  @Test func documentGrowthChangesVisibilityWithoutInventingUserIntent() {
    let scroll = makeScroll(flipped: true)
    var visibility: [Bool] = []
    var reports: [Bool] = []
    let observer = ConversationScrollObserver.Coordinator(onBottomVisibilityChange: {
      visibility.append($0)
    }) { bottom, _ in reports.append(bottom) }
    observer.attach(to: scroll)
    scroll.documentView!.setFrameSize(NSSize(width: 300, height: 1200))
    observer.reportPosition()
    #expect(visibility == [true, false])
    #expect(reports.isEmpty)
    scroll.documentView!.setFrameSize(NSSize(width: 300, height: 1400))
    observer.reportPosition()
    // HTML/图片持续定高时，即使 bottom 仍为 false，也应再次请求跟随校正。
    #expect(visibility == [true, false, false])
    #expect(reports.isEmpty)
  }

  @Test func representableAttachesAfterItsNativeHierarchyIsInstalled() async throws {
    var visibility: [Bool] = []
    var userReports: [Bool] = []
    let host = NSHostingView(rootView:
      ScrollView {
        Color.clear.frame(height: 6000).background {
          ConversationScrollObserver(
            onUserScroll: { bottom, _ in userReports.append(bottom) },
            onBottomVisibilityChange: { visibility.append($0) }
          ).allowsHitTesting(false)
        }
      }.frame(width: 500, height: 400))
    host.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.contentView = nil }
    try await Task.sleep(for: .milliseconds(250))
    func findScroll(_ view: NSView) -> NSScrollView? {
      if let scroll = view as? NSScrollView { return scroll }
      return view.subviews.lazy.compactMap(findScroll).first
    }
    let scroll = try #require(findScroll(host))
    #expect(!visibility.isEmpty)
    moveToBottom(scroll)
    try await Task.sleep(for: .milliseconds(50))
    #expect(visibility.last == true)
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    var origin = scroll.contentView.bounds.origin
    origin.y += scroll.contentView.isFlipped ? -120 : 120
    scroll.contentView.scroll(to: origin)
    try await Task.sleep(for: .milliseconds(50))
    #expect(visibility.last == false)
    #expect(userReports.last == false)
  }

  @Test func horizontalOnlyInputDoesNotAffectFollowing() {
    let scroll = makeScroll(flipped: true)
    var count = 0
    let observer = ConversationScrollObserver.Coordinator(onBottomVisibilityChange: { _ in }) {
      _, _ in count += 1
    }
    observer.attach(to: scroll)
    observer.handleScrollWheel(scrollingDeltaY: 0)
    #expect(count == 0)
  }
}

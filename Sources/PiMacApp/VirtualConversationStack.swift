import AppKit
import Observation
import SwiftUI

/// Disclosure state outlives recycled message views, just like measured heights.
@Observable
final class ConversationExpansionStore {
  var values: [String: Bool] = [:]
}

private struct ConversationExpansionStoreKey: EnvironmentKey {
  static let defaultValue: ConversationExpansionStore? = nil
}

extension EnvironmentValues {
  var conversationExpansionStore: ConversationExpansionStore? {
    get { self[ConversationExpansionStoreKey.self] }
    set { self[ConversationExpansionStoreKey.self] = newValue }
  }
}

/// Explicit geometry for a windowed transcript. Unmeasured rows use an estimate, but
/// measured rows retain their height after their SwiftUI views have been recycled.
struct ConversationWindowLayout {
  let offsets: [CGFloat]

  init(ids: [String], heights: [String: CGFloat], estimate: CGFloat = 320, spacing: CGFloat = 14) {
    var offsets: [CGFloat] = [0]
    offsets.reserveCapacity(ids.count + 1)
    for id in ids {
      offsets.append(offsets.last! + max(1, heights[id] ?? estimate) + spacing)
    }
    self.offsets = offsets
  }

  var count: Int { offsets.count - 1 }
  var height: CGFloat { offsets.last ?? 0 }

  func index(at y: CGFloat) -> Int {
    guard count > 0 else { return 0 }
    var low = 0
    var high = count
    while low < high {
      let middle = (low + high) / 2
      if offsets[middle + 1] <= y { low = middle + 1 } else { high = middle }
    }
    return min(low, count - 1)
  }

  func window(viewport: CGRect?) -> Range<Int> {
    guard count > 0 else { return 0..<0 }
    // Before AppKit reports its first viewport, prepare the end of the session.
    let viewport = viewport ?? CGRect(x: 0, y: max(0, height - 900), width: 0, height: 900)
    let overscan = max(600, viewport.height)
    let first = index(at: max(0, viewport.minY - overscan))
    let last = index(at: viewport.maxY + overscan)
    return first..<max(first + 1, last + 1)
  }

  func anchorCorrection(to updated: Self, viewportY: CGFloat) -> CGFloat {
    guard count > 0, updated.count == count else { return 0 }
    let anchor = index(at: viewportY)
    return updated.offsets[anchor] - offsets[anchor]
  }
}

private struct ConversationRowMeasurement: Equatable {
  let height: CGFloat
  let width: CGFloat
}

private struct ConversationRowHeights: PreferenceKey {
  static var defaultValue: [String: ConversationRowMeasurement] = [:]
  static func reduce(
    value: inout [String: ConversationRowMeasurement],
    nextValue: () -> [String: ConversationRowMeasurement]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

/// Only the viewport plus overscan and the live tail have expensive message views.
/// Spacer heights are controlled by us, rather than LazyVStack's changing estimates.
struct VirtualConversationStack<Row: View>: View {
  let ids: [String]
  let pinnedToBottom: Bool
  @ViewBuilder let row: (Int) -> Row

  @State private var heights: [String: CGFloat] = [:]
  @State private var viewport: CGRect?
  @State private var measuredWidth: CGFloat = 0
  @State private var scroll = ConversationViewportController()
  @State private var expansionStore = ConversationExpansionStore()

  private let spacing: CGFloat = 14

  private struct Block: Identifiable {
    let id: String
    let index: Int?
    let height: CGFloat
  }

  var body: some View {
    let layout = ConversationWindowLayout(ids: ids, heights: heights)
    let window = layout.window(viewport: viewport)
    let blocks = blocks(layout: layout, window: window)

    VStack(alignment: .leading, spacing: 0) {
      ForEach(blocks) { block in
        if let index = block.index {
          row(index)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background {
              GeometryReader { geometry in
                Color.clear.preference(
                  key: ConversationRowHeights.self,
                  value: [
                    ids[index]: ConversationRowMeasurement(
                      height: geometry.size.height, width: geometry.size.width
                    )
                  ]
                )
              }
            }
            // Measure intrinsic content BEFORE imposing the cached height. This keeps
            // the document geometry deterministic while measurements are reconciled.
            .frame(height: max(1, block.height - spacing), alignment: .topLeading)
            .clipped()
            .padding(.bottom, spacing)
        } else {
          Color.clear.frame(height: block.height)
        }
      }
    }
    .background {
      ConversationViewportReader(controller: scroll) { rect, _ in
        if viewport != rect { viewport = rect }
      }
    }
    .onPreferenceChange(ConversationRowHeights.self) { measured in
      guard let width = measured.values.first?.width, width > 0 else { return }
      // Invalidate old wrapping measurements atomically with the new visible heights;
      // clearing them separately can lose a preference whose value hasn't changed.
      let widthChanged = abs(width - measuredWidth) > 0.5
      var updated = widthChanged ? [:] : heights
      if widthChanged { measuredWidth = width }
      for (id, measurement) in measured
      where measurement.height.isFinite && measurement.height > 0
        && abs(measurement.width - width) <= 0.5
      {
        if abs((updated[id] ?? -1) - measurement.height) > 0.5 {
          updated[id] = measurement.height
        }
      }
      replaceHeights(updated, layout: layout, viewportY: viewport?.minY ?? 0)
    }
    .onChange(of: ids) {
      let validIDs = Set(ids)
      heights = heights.filter { validIDs.contains($0.key) }
    }
    .environment(\.conversationExpansionStore, expansionStore)
    .transaction { $0.animation = nil }
  }

  private func blocks(layout: ConversationWindowLayout, window: Range<Int>) -> [Block] {
    guard !ids.isEmpty else { return [] }
    // Keep the newest turn mounted even when reading history: streaming must never
    // modify a recycled lazy row. It has the same identity when it becomes history.
    var indices = Array(window)
    if !window.contains(ids.count - 1) { indices.append(ids.count - 1) }
    var result: [Block] = []
    var previousEnd: CGFloat = 0
    for index in indices {
      let start = layout.offsets[index]
      if start > previousEnd {
        result.append(
          Block(id: "gap-before-" + ids[index], index: nil, height: start - previousEnd))
      }
      let end = layout.offsets[index + 1]
      result.append(Block(id: "row-" + ids[index], index: index, height: end - start))
      previousEnd = end
    }
    return result
  }

  private func replaceHeights(
    _ updated: [String: CGFloat], layout: ConversationWindowLayout, viewportY: CGFloat
  ) {
    guard heights != updated else { return }
    let next = ConversationWindowLayout(ids: ids, heights: updated)
    let correction = layout.anchorCorrection(to: next, viewportY: viewportY)
    // Capture the reading position before changing document height. In bottom-follow
    // mode the parent owns scrolling; while reading history only preceding rows matter.
    if !pinnedToBottom {
      // Also restore a zero-delta anchor: live-tail growth below the viewport
      // must not let SwiftUI's default bottom anchor move the reader.
      scroll.preservePosition(adding: correction)
      if var rect = viewport {
        rect.origin.y += correction
        viewport = rect
      }
    }
    heights = updated
  }
}

private final class ConversationViewportController {
  weak var view: NSView?
  private var pendingOrigin: NSPoint?
  private var pendingUserGeneration = 0
  var userGeneration = 0
  var isRestoring: Bool { pendingOrigin != nil }

  func preservePosition(adding delta: CGFloat) {
    guard let scrollView = view?.enclosingScrollView else { return }
    if pendingOrigin != nil, pendingUserGeneration == userGeneration {
      pendingOrigin!.y += delta
      return
    }
    var origin = scrollView.contentView.bounds.origin
    origin.y += delta
    pendingOrigin = origin
    pendingUserGeneration = userGeneration
  }

  // Called after SwiftUI has updated the representable, not before the height
  // change has reached AppKit (which would clamp against the old document size).
  func restorePosition() {
    guard let origin = pendingOrigin, let scrollView = view?.enclosingScrollView else { return }
    pendingOrigin = nil
    guard pendingUserGeneration == userGeneration else { return }
    scrollView.layoutSubtreeIfNeeded()
    let clip = scrollView.contentView
    var bounds = clip.bounds
    bounds.origin = origin
    clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
    scrollView.reflectScrolledClipView(clip)
  }
}

private struct ConversationViewportReader: NSViewRepresentable {
  let controller: ConversationViewportController
  let onChange: (CGRect, CGFloat) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = FlippedView()
    controller.view = view
    return view
  }

  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    coordinator.active = false
    coordinator.observers.forEach(NotificationCenter.default.removeObserver)
    coordinator.observers.removeAll()
    coordinator.onChange = nil
    coordinator.controller = nil
  }

  func updateNSView(_ view: NSView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onChange = onChange
    coordinator.controller = controller
    DispatchQueue.main.async { [weak view] in
      guard let view, coordinator.active else { return }
      coordinator.attach(view)
      controller.restorePosition()
      coordinator.report()
    }
  }

  private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
  }

  final class Coordinator {
    weak var view: NSView?
    weak var observedScrollView: NSScrollView?
    var controller: ConversationViewportController?
    var onChange: ((CGRect, CGFloat) -> Void)?
    var observers: [NSObjectProtocol] = []
    var reportScheduled = false
    var active = true

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func attach(_ view: NSView) {
      self.view = view
      guard let scroll = view.enclosingScrollView, observedScrollView !== scroll else { return }
      observers.forEach(NotificationCenter.default.removeObserver)
      observers.removeAll()
      observedScrollView = scroll
      scroll.contentView.postsBoundsChangedNotifications = true
      observers.append(
        NotificationCenter.default.addObserver(
          forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in self?.scheduleReport() })
      for name in [
        NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification,
      ] {
        observers.append(
          NotificationCenter.default.addObserver(
            forName: name, object: scroll, queue: .main
          ) { [weak self] _ in self?.controller?.userGeneration += 1 })
      }
    }

    func scheduleReport() {
      guard !reportScheduled else { return }
      reportScheduled = true
      DispatchQueue.main.async { [weak self] in
        self?.reportScheduled = false
        self?.report()
      }
    }

    func report() {
      guard active, controller?.isRestoring != true,
        let view, let clip = view.enclosingScrollView?.contentView,
        view.bounds.width > 0, clip.bounds.height > 0
      else { return }
      onChange?(view.convert(clip.bounds, from: clip), view.bounds.width)
    }
  }
}

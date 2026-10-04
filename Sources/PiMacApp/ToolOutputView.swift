import AppKit
import SwiftUI

/// A native, eagerly laid-out text surface. SwiftUI's selectable Text inside a
/// two-axis ScrollView can leave its glyph layer blank until the first click,
/// especially when transcript rows are recycled or output grows offscreen.
struct ToolOutputView: NSViewRepresentable {
  let text: String
  var searchSelection: NSRange? = nil
  var wrapsLines = false
  var searchMatches: [NSRange] = []
  var followsTail = false
  var maximumHeight: CGFloat = 300

  func makeNSView(context: Context) -> ToolOutputScrollView {
    ToolOutputScrollView()
  }

  func updateNSView(_ view: ToolOutputScrollView, context: Context) {
    view.setWrapsLines(wrapsLines)
    view.setOutput(text)
    view.setSearchMatches(searchMatches)
    view.setSearchSelection(searchSelection)
    view.setFollowsTail(followsTail && searchSelection == nil)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: ToolOutputScrollView, context: Context
  ) -> CGSize? {
    let width = proposal.width.flatMap { $0.isFinite ? max(1, $0) : nil } ?? 400
    nsView.prepareLayout(viewportWidth: width)
    return CGSize(width: width, height: min(maximumHeight, nsView.outputSize.height))
  }
}

final class ToolOutputScrollView: NSScrollView {
  let outputTextView: NSTextView
  private(set) var outputSize = CGSize(width: 18, height: 18)
  private let inset: CGFloat = 9
  private var searchSelection: NSRange?
  private(set) var searchMatches: [NSRange] = []
  private var followsTail = false
  private(set) var wrapsLines = false
  private var layoutWidth: CGFloat = 0

  init() {
    // Use TextKit 1 explicitly so glyph layout does not depend on interaction
    // with a lazily created TextKit 2 viewport.
    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    let container = NSTextContainer(containerSize: CGSize(width: 10_000_000, height: 10_000_000))
    storage.addLayoutManager(manager)
    manager.addTextContainer(container)
    container.widthTracksTextView = false
    container.heightTracksTextView = false
    container.lineFragmentPadding = 0
    container.lineBreakMode = .byClipping
    outputTextView = NSTextView(frame: .zero, textContainer: container)
    super.init(frame: .zero)
    drawsBackground = false
    borderType = .noBorder
    hasHorizontalScroller = true
    hasVerticalScroller = true
    autohidesScrollers = true
    scrollerStyle = .overlay
    outputTextView.isEditable = false
    outputTextView.isSelectable = true
    outputTextView.isRichText = false
    outputTextView.drawsBackground = false
    outputTextView.isHorizontallyResizable = false
    outputTextView.isVerticallyResizable = false
    outputTextView.textContainerInset = CGSize(width: inset, height: inset)
    outputTextView.font = .monospacedSystemFont(
      ofSize: NSFont.smallSystemFontSize, weight: .regular)
    outputTextView.textColor = .labelColor
    documentView = outputTextView
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func setOutput(_ text: String) {
    guard outputTextView.string != text,
      let manager = outputTextView.layoutManager,
      let container = outputTextView.textContainer
    else { return }
    let selection = outputTextView.selectedRange()
    manager.removeTemporaryAttribute(
      .backgroundColor,
      forCharacterRange: NSRange(location: 0, length: (outputTextView.string as NSString).length))
    outputTextView.string = text
    // The same range may now refer to different text. Reapply it after replacement,
    // but preserve manual selections across unrelated SwiftUI updates.
    searchSelection = nil
    searchMatches = []
    let length = (text as NSString).length
    let start = min(selection.location, length)
    outputTextView.setSelectedRange(
      NSRange(location: start, length: min(selection.length, length - start)))
    updateOutputSize(manager: manager, container: container)
    resizeDocument()
    outputTextView.needsDisplay = true
    contentView.needsDisplay = true
    needsLayout = true
  }

  private func updateOutputSize(manager: NSLayoutManager, container: NSTextContainer) {
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container)
    // TextKit can report the entire fragment width after toggling wrapping,
    // including millions of points of trailing whitespace. Measure actual glyphs.
    let glyphs = manager.boundingRect(
      forGlyphRange: manager.glyphRange(for: container), in: container)
    let lineHeight = manager.defaultLineHeight(for: outputTextView.font!)
    outputSize = CGSize(
      width: ceil(glyphs.maxX) + inset * 2,
      height: ceil(max(lineHeight, used.maxY)) + inset * 2
    )
  }

  func setWrapsLines(_ wraps: Bool) {
    guard wraps != wrapsLines else { return }
    wrapsLines = wraps
    outputTextView.textContainer?.lineBreakMode = wraps ? .byWordWrapping : .byClipping
    hasHorizontalScroller = !wraps
    layoutWidth = 0
    needsLayout = true
  }

  func setSearchSelection(_ range: NSRange?) {
    guard range != searchSelection else { return }
    guard let range else {
      searchSelection = nil
      return
    }
    let length = (outputTextView.string as NSString).length
    // Validate by subtraction: NSMaxRange can overflow for untrusted ranges.
    guard range.location >= 0, range.location <= length,
      range.length >= 0, range.length <= length - range.location
    else { return }
    searchSelection = range
    outputTextView.setSelectedRange(range)
    outputTextView.scrollRangeToVisible(range)
  }

  /// Temporary layout attributes never alter copied/exported text or manual selections.
  func setSearchMatches(_ ranges: [NSRange]) {
    guard ranges != searchMatches, let manager = outputTextView.layoutManager else { return }
    let length = (outputTextView.string as NSString).length
    manager.removeTemporaryAttribute(
      .backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
    searchMatches = Array(ranges.prefix(ToolOutputPresentation.maximumMatches)).filter {
      $0.location >= 0 && $0.location <= length && $0.length > 0
        && $0.length <= length - $0.location
    }
    for range in searchMatches {
      manager.addTemporaryAttribute(
        .backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.25),
        forCharacterRange: range)
    }
  }

  func setFollowsTail(_ follows: Bool) {
    followsTail = follows
    if follows { scrollToTail() }
  }

  private func scrollToTail() {
    let y = max(0, outputTextView.frame.height - contentView.bounds.height)
    contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: y))
    reflectScrolledClipView(contentView)
  }

  /// SwiftUI must measure wrapped height before assigning the native view's frame.
  func prepareLayout(viewportWidth: CGFloat) {
    if let manager = outputTextView.layoutManager,
      let container = outputTextView.textContainer
    {
      let width = wrapsLines ? max(1, viewportWidth - inset * 2) : 10_000_000
      if width != layoutWidth {
        layoutWidth = width
        container.containerSize = CGSize(width: width, height: 10_000_000)
        updateOutputSize(manager: manager, container: container)
        invalidateIntrinsicContentSize()
      }
    }
  }

  override func layout() {
    super.layout()
    prepareLayout(viewportWidth: contentView.bounds.width)
    resizeDocument()
    if followsTail { scrollToTail() }
  }

  private func resizeDocument() {
    outputTextView.setFrameSize(
      CGSize(
        width: max(outputSize.width, contentView.bounds.width),
        height: max(outputSize.height, contentView.bounds.height)
      ))
  }
}

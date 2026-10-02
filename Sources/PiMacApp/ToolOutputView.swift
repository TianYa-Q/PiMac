import AppKit
import SwiftUI

/// A native, eagerly laid-out text surface. SwiftUI's selectable Text inside a
/// two-axis ScrollView can leave its glyph layer blank until the first click,
/// especially when transcript rows are recycled or output grows offscreen.
struct ToolOutputView: NSViewRepresentable {
  let text: String

  func makeNSView(context: Context) -> ToolOutputScrollView {
    ToolOutputScrollView()
  }

  func updateNSView(_ view: ToolOutputScrollView, context: Context) {
    view.setOutput(text)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: ToolOutputScrollView, context: Context
  ) -> CGSize? {
    CGSize(width: proposal.width ?? 400, height: min(300, nsView.outputSize.height))
  }
}

final class ToolOutputScrollView: NSScrollView {
  let outputTextView: NSTextView
  private(set) var outputSize = CGSize(width: 18, height: 18)
  private let inset: CGFloat = 9

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
    outputTextView.string = text
    let length = (text as NSString).length
    let start = min(selection.location, length)
    outputTextView.setSelectedRange(
      NSRange(location: start, length: min(selection.length, length - start)))
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container)
    let lineHeight = manager.defaultLineHeight(for: outputTextView.font!)
    outputSize = CGSize(
      width: ceil(used.maxX) + inset * 2,
      height: ceil(max(lineHeight, used.maxY)) + inset * 2
    )
    resizeDocument()
    outputTextView.needsDisplay = true
    contentView.needsDisplay = true
    needsLayout = true
  }

  override func layout() {
    super.layout()
    resizeDocument()
  }

  private func resizeDocument() {
    outputTextView.setFrameSize(
      CGSize(
        width: max(outputSize.width, contentView.bounds.width),
        height: max(outputSize.height, contentView.bounds.height)
      ))
  }
}

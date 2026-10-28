import AppKit
import SwiftUI

/// 始终用同一个 TextKit 排版器测量、绘制和选择，避免 SwiftUI Text 点击后切换
/// field editor，混合字体的换行/行高改变却不重新向消息容器报告高度。
struct SelectableMarkdownText: NSViewRepresentable {
  let blocks: [MarkdownBlock]
  let textStyle: NSFont.TextStyle

  func makeNSView(context: Context) -> MarkdownTextView {
    MarkdownTextView()
  }

  func updateNSView(_ view: MarkdownTextView, context: Context) {
    view.setContent(blocks: blocks, textStyle: textStyle)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: MarkdownTextView, context: Context
  ) -> CGSize? {
    guard let width = proposal.width, width.isFinite else { return nil }
    return nsView.measuredSize(width: width)
  }
}

final class MarkdownTextView: NSTextView {
  private var renderedBlocks: [MarkdownBlock]?
  private var renderedStyle: NSFont.TextStyle?
  private var measuredSizes: [CGFloat: CGSize] = [:]

  init() {
    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 0, height: 10_000_000))
    storage.addLayoutManager(manager)
    manager.addTextContainer(container)
    container.lineFragmentPadding = 0
    container.widthTracksTextView = true
    container.heightTracksTextView = false
    super.init(frame: .zero, textContainer: container)
    isEditable = false
    isSelectable = true
    isRichText = true
    drawsBackground = false
    textContainerInset = .zero
    isHorizontallyResizable = false
    isVerticallyResizable = false
    minSize = .zero
    maxSize = CGSize(width: 10_000_000, height: 10_000_000)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func setContent(blocks: [MarkdownBlock], textStyle: NSFont.TextStyle) {
    // 流式尾部或滚动触发父视图更新时，已完成正文不再重建整份富文本。
    guard renderedBlocks != blocks || renderedStyle != textStyle else { return }
    setText(MarkdownTextContent.attributedString(blocks: blocks, textStyle: textStyle))
    renderedBlocks = blocks
    renderedStyle = textStyle
  }

  func setText(_ value: NSAttributedString) {
    renderedBlocks = nil
    renderedStyle = nil
    guard let storage = textStorage, !storage.isEqual(to: value) else { return }
    measuredSizes.removeAll(keepingCapacity: true)
    let selection = selectedRange()
    let sameText = string == value.string
    storage.setAttributedString(value)
    // 主题/样式更新不应丢失用户正在引用的选区；正文改变则交给 AppKit 校正。
    if sameText { setSelectedRange(selection) }
    invalidateIntrinsicContentSize()
  }

  func measuredSize(width: CGFloat) -> CGSize {
    guard let container = textContainer, let manager = layoutManager else { return .zero }
    let width = max(1, width)
    if let cached = measuredSizes[width] { return cached }
    // SwiftUI 会试探多个宽度，最后一次试探不一定等于最终 frame。
    // 测量后恢复实际绘制宽度，不能让一次窄宽度探测改变用户看到的排版。
    defer {
      container.containerSize = CGSize(width: max(1, bounds.width), height: 10_000_000)
    }
    container.containerSize = CGSize(width: width, height: 10_000_000)
    manager.ensureLayout(for: container)
    let size = CGSize(width: width, height: ceil(manager.usedRect(for: container).maxY))
    // 精确按宽度缓存，避免输出期间反复试探相同宽度，让长正文整篇重排。
    // 限制每个挂载视图的缓存；正文/字体改变时由 setText 整体失效。
    if measuredSizes.count >= 8 { measuredSizes.removeAll(keepingCapacity: true) }
    measuredSizes[width] = size
    return size
  }
}

@MainActor
enum MarkdownTextContent {
  static func attributedString(blocks: [MarkdownBlock], textStyle: NSFont.TextStyle)
    -> NSAttributedString
  {
    let result = NSMutableAttributedString(string: "")
    let bodyFont = NSFont.preferredFont(forTextStyle: textStyle)
    let secondary = NSColor.secondaryLabelColor

    func append(
      _ text: String, font: NSFont = bodyFont, color: NSColor = .labelColor, markdown: Bool = true
    ) {
      guard markdown else {
        result.append(
          NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        return
      }
      let value = MarkdownInlineCache.attributedString(for: text)
      for run in value.runs {
        let intent = run.inlinePresentationIntent ?? []
        var runFont =
          intent.contains(.code)
          ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) : font
        var traits: NSFontTraitMask = []
        if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
        if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
        if !traits.isEmpty { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: traits) }
        var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color]
        if let link = run.link { attributes[.link] = link }
        if intent.contains(.strikethrough) {
          attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        result.append(
          NSAttributedString(string: String(value[run.range].characters), attributes: attributes))
      }
    }

    for (index, block) in blocks.enumerated() {
      if index > 0 { append("\n\n", markdown: false) }
      switch block {
      case .paragraph(let text):
        append(text)
      case .heading(let level, let text):
        let style: NSFont.TextStyle =
          switch level {
          case 1: .title1
          case 2: .title2
          case 3: .title3
          default: .headline
          }
        let font = NSFontManager.shared.convert(
          NSFont.preferredFont(forTextStyle: style), toHaveTrait: .boldFontMask)
        append(text, font: font)
      case .code(let language, let text):
        if let language {
          append(
            language + "\n", font: .preferredFont(forTextStyle: .caption2), color: secondary,
            markdown: false)
        }
        append(
          text.isEmpty ? " " : text,
          font: .monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular), markdown: false
        )
      case .quote(let text):
        append("▎ ", color: .controlAccentColor, markdown: false)
        append(text.replacingOccurrences(of: "\n", with: "\n▎ "), color: secondary)
      case .list(let ordered, let start, let items):
        for (offset, item) in items.enumerated() {
          if offset > 0 { append("\n", markdown: false) }
          let unchecked = item.hasPrefix("[ ] ")
          let checked = item.lowercased().hasPrefix("[x] ")
          let marker = ordered ? "\(start + offset). " : unchecked ? "☐ " : checked ? "☑ " : "• "
          append(marker, color: secondary, markdown: false)
          append(unchecked || checked ? String(item.dropFirst(4)) : item)
        }
      case .divider:
        append("────────────────────────", color: secondary, markdown: false)
      case .table:
        break  // 表格由 MarkdownTableView 独立布局，不进入连续可选正文。
      }
    }
    return result
  }
}

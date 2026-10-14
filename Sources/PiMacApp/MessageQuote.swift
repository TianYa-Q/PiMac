import AppKit
import SwiftUI

/// 引用直接进入普通草稿，复用既有的保存、排队、发送和失败恢复流程。
enum MessageQuote {
  static func inserting(_ quote: String, into text: String, selection: NSRange)
    -> (text: String, selection: NSRange)?
  {
    let value = quote.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    let source = text as NSString
    let location = min(max(0, selection.location), source.length)
    let length = min(max(0, selection.length), source.length - location)
    let range = NSRange(location: location, length: length)
    let prefix = source.substring(to: location)
    let separator = prefix.isEmpty || prefix.hasSuffix("\n\n") ? "" : prefix.hasSuffix("\n") ? "\n" : "\n\n"
    let block = value.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
    let replacement = separator + block + "\n\n"
    return (
      source.replacingCharacters(in: range, with: replacement),
      NSRange(location: location + replacement.utf16.count, length: 0)
    )
  }
}

private struct MessageQuoteActionKey: EnvironmentKey {
  static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
  var messageQuoteAction: ((String) -> Void)? {
    get { self[MessageQuoteActionKey.self] }
    set { self[MessageQuoteActionKey.self] = newValue }
  }
}

/// SwiftUI 的可选 Text 并非 NSTextView。通过公开的辅助功能接口读取选区，
/// 不触发 copy、不改用户剪贴板，也不把输入框或其他消息的选区误当作当前引用。
struct MessageSelectionReader: NSViewRepresentable {
  let onSelection: (String) -> Void

  func makeNSView(context: Context) -> SelectionAnchor {
    SelectionAnchor(onSelection: onSelection)
  }

  func updateNSView(_ view: SelectionAnchor, context: Context) {
    view.onSelection = onSelection
  }

  static func dismantleNSView(_ view: SelectionAnchor, coordinator: ()) {
    view.stopMonitoring()
  }

  final class SelectionAnchor: NSView {
    var onSelection: (String) -> Void
    private var monitor: Any?

    init(onSelection: @escaping (String) -> Void) {
      self.onSelection = onSelection
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopMonitoring()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyUp]) { [weak self] event in
        guard let self, event.window === self.window else { return event }
        // 本地 monitor 先于 Text 处理事件；下一次主队列读取最终选区。
        DispatchQueue.main.async { [weak self] in self?.refreshSelection() }
        return event
      }
    }

    func stopMonitoring() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    func refreshSelection() {
      guard let root = window?.contentView, !isHiddenOrHasHiddenAncestor else {
        onSelection("")
        return
      }
      let area = convert(bounds, to: root)
      func selectedText(in view: NSView) -> String? {
        guard view !== self, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let rect = view.convert(view.bounds, to: root)
        guard rect.intersects(area) else { return nil }
        // 只接受落在消息正文内的可选文本；祖先的聚合 AX 值不能用于归属判断。
        if area.contains(NSPoint(x: rect.midX, y: rect.midY)),
          let text = view.accessibilitySelectedText(),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          return text
        }
        for child in view.subviews {
          if let text = selectedText(in: child) { return text }
        }
        return nil
      }
      onSelection(selectedText(in: root) ?? "")
    }
  }
}

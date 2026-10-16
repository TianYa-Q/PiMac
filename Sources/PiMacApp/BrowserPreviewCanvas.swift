import AppKit
import SwiftUI

struct BrowserPreviewCanvas: NSViewRepresentable {
  let image: NSImage?
  let viewport: CGSize
  let interactive: Bool
  let send: (T3BrowserInput) -> Void
  let resize: (CGSize) -> Void

  func makeNSView(context: Context) -> BrowserPreviewInputView { BrowserPreviewInputView() }
  func updateNSView(_ view: BrowserPreviewInputView, context: Context) {
    view.image = image
    view.viewport = viewport
    view.send = send
    view.resize = resize
    view.interactive = interactive
    view.needsDisplay = true
    // 输入焦点只由用户点击获取；代理画面刷新不能抢走聊天输入框的焦点。
    if !interactive, view.window?.firstResponder === view {
      view.unmarkText()
      view.window?.makeFirstResponder(nil)
    }
  }
}

/// 原生画面而非打开相同 URL 的 WKWebView：所有输入都驱动 Server 上的同一个标签。
final class BrowserPreviewInputView: NSView, NSTextInputClient {
  var image: NSImage?
  var viewport: CGSize = .zero
  var interactive = false
  var send: (T3BrowserInput) -> Void = { _ in }
  var resize: (CGSize) -> Void = { _ in }
  private var marked = NSMutableAttributedString(string: "")
  private var markedSelection = NSRange(location: 0, length: 0)
  private var interpretingEvent: NSEvent?
  private var pressedKeys: [UInt16: NSEvent] = [:]
  private var pressedButtons: [String: CGPoint] = [:]
  private var blurObserver: NSObjectProtocol?
  private var lastPoint: CGPoint = .zero

  deinit { if let blurObserver { NotificationCenter.default.removeObserver(blurObserver) } }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let blurObserver { NotificationCenter.default.removeObserver(blurObserver) }
    blurObserver = nil
    guard let window else {
      releaseInput()
      return
    }
    blurObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: window, queue: .main
    ) { [weak self] _ in self?.releaseInput() }
  }

  override func resignFirstResponder() -> Bool {
    releaseInput()
    return super.resignFirstResponder()
  }

  private func releaseInput() {
    for event in pressedKeys.values { key(event, action: "up") }
    pressedKeys.removeAll()
    for (button, point) in pressedButtons {
      send(.mouse(action: "up", point: point, button: button, buttons: 0, count: 1, modifiers: 0))
    }
    pressedButtons.removeAll()
    unmarkText()
  }
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { interactive }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    bounds.fill()
    guard let image else { return }
    image.draw(
      in: BrowserPreviewGeometry.imageRect(image: image.size, bounds: bounds),
      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    if hasMarkedText() {
      marked.draw(at: CGPoint(x: lastPoint.x, y: min(bounds.height - 24, lastPoint.y + 12)))
    }
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    // 下一轮提交给模型，避免 NSViewRepresentable 更新期间反向修改 SwiftUI 状态。
    DispatchQueue.main.async { [weak self] in
      guard let self, self.window != nil, self.frame.size == newSize else { return }
      self.resize(newSize)
    }
  }

  private func point(_ event: NSEvent, clamp: Bool) -> CGPoint? {
    guard interactive, let image else { return nil }
    let local = convert(event.locationInWindow, from: nil)
    lastPoint = local
    return BrowserPreviewGeometry.point(
      local,
      imageRect: BrowserPreviewGeometry.imageRect(image: image.size, bounds: bounds),
      viewport: viewport, clamp: clamp)
  }

  static func modifiers(_ flags: NSEvent.ModifierFlags) -> Int {
    (flags.contains(.option) ? 1 : 0) | (flags.contains(.control) ? 2 : 0)
      | (flags.contains(.command) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0)
  }

  private func mouse(_ event: NSEvent, action: String) {
    guard let point = point(event, clamp: action != "down") else { return }
    if action == "down" { window?.makeFirstResponder(self) }
    let button = event.buttonNumber == 0 ? "left" : event.buttonNumber == 1 ? "right" : "middle"
    if action == "up" {
      pressedButtons.removeValue(forKey: button)
    } else {
      pressedButtons[button] = point
    }
    send(
      .mouse(
        action: action, point: point, button: button,
        buttons: Int(NSEvent.pressedMouseButtons), count: event.clickCount,
        modifiers: Self.modifiers(event.modifierFlags)))
  }
  override func mouseDown(with event: NSEvent) { mouse(event, action: "down") }
  override func mouseUp(with event: NSEvent) { mouse(event, action: "up") }
  override func mouseDragged(with event: NSEvent) { mouse(event, action: "move") }
  override func rightMouseDown(with event: NSEvent) { mouse(event, action: "down") }
  override func rightMouseUp(with event: NSEvent) { mouse(event, action: "up") }
  override func rightMouseDragged(with event: NSEvent) { mouse(event, action: "move") }
  override func otherMouseDown(with event: NSEvent) { mouse(event, action: "down") }
  override func otherMouseUp(with event: NSEvent) { mouse(event, action: "up") }
  override func otherMouseDragged(with event: NSEvent) { mouse(event, action: "move") }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
  }
  override func mouseMoved(with event: NSEvent) {
    guard let point = point(event, clamp: false) else { return }
    send(
      .mouse(
        action: "move", point: point, button: "none", buttons: 0, count: 0,
        modifiers: Self.modifiers(event.modifierFlags)))
  }
  override func scrollWheel(with event: NSEvent) {
    guard let point = point(event, clamp: false) else { return }
    let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 32
    send(
      .wheel(
        point: point,
        delta: CGSize(
          width: -event.scrollingDeltaX * scale, height: -event.scrollingDeltaY * scale),
        modifiers: Self.modifiers(event.modifierFlags)))
  }

  private static let keys: [UInt16: (String, String, Int)] = [
    36: ("Enter", "Enter", 13), 76: ("Enter", "NumpadEnter", 13),
    48: ("Tab", "Tab", 9), 51: ("Backspace", "Backspace", 8),
    53: ("Escape", "Escape", 27), 117: ("Delete", "Delete", 46),
    123: ("ArrowLeft", "ArrowLeft", 37), 124: ("ArrowRight", "ArrowRight", 39),
    125: ("ArrowDown", "ArrowDown", 40), 126: ("ArrowUp", "ArrowUp", 38),
    115: ("Home", "Home", 36), 119: ("End", "End", 35),
    116: ("PageUp", "PageUp", 33), 121: ("PageDown", "PageDown", 34),
  ]

  private func key(_ event: NSEvent, action: String) {
    let character = event.charactersIgnoringModifiers ?? ""
    let mapped = Self.keys[event.keyCode]
    let name = mapped?.0 ?? character
    let code: String
    if let mapped {
      code = mapped.1
    } else if character == " " {
      code = "Space"
    } else if character.count == 1, ("a"..."z").contains(character.lowercased()) {
      code = "Key\(character.uppercased())"
    } else if character.count == 1, ("0"..."9").contains(character) {
      code = "Digit\(character)"
    } else {
      code = ""
    }
    let virtual = mapped?.2 ?? Int(character.uppercased().utf16.first ?? 0)
    let modifiers = Self.modifiers(event.modifierFlags)
    let text: String?
    if action == "down", modifiers & 6 == 0 {
      text = mapped?.0 == "Enter" ? "\r" : (mapped == nil ? event.characters : nil)
    } else {
      text = nil
    }
    send(
      .key(
        action: action, key: name, code: code, keyCode: virtual,
        modifiers: modifiers, text: text))
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard interactive, window?.firstResponder === self, event.modifierFlags.contains(.command),
      ["a", "c", "x", "v", "z", "y"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "")
    else { return super.performKeyEquivalent(with: event) }
    keyDown(with: event)
    // 菜单快捷键不保证把 keyUp 交给本视图；立即配对，避免远端留下按住的编辑键。
    keyUp(with: event)
    return true
  }

  override func keyDown(with event: NSEvent) {
    guard interactive else { return }
    if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
      if event.modifierFlags.contains(.command),
        event.charactersIgnoringModifiers?.lowercased() == "v"
      {
        if let text = NSPasteboard.general.string(forType: .string) {
          insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
      } else {
        key(event, action: "down")
        pressedKeys[event.keyCode] = event
      }
    } else if !hasMarkedText(), Self.keys[event.keyCode] != nil {
      key(event, action: "down")
      pressedKeys[event.keyCode] = event
    } else {
      interpretingEvent = event
      defer { interpretingEvent = nil }
      interpretKeyEvents([event])
    }
  }

  override func keyUp(with event: NSEvent) {
    if pressedKeys.removeValue(forKey: event.keyCode) != nil, interactive {
      key(event, action: "up")
    }
  }

  func insertText(_ string: Any, replacementRange: NSRange) {
    guard interactive else { return }
    let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
    let composing = hasMarkedText()
    unmarkText()
    // 普通按键保留 DOM keydown/up（例如空格激活按钮、页面快捷键）；
    // 中文输入法的提交与粘贴则使用 insertText，不把预编辑过程发送到网页。
    if !composing, let event = interpretingEvent, event.characters == text,
      text.utf8.count == 1, let byte = text.utf8.first, (32...126).contains(byte)
    {
      key(event, action: "down")
      pressedKeys[event.keyCode] = event
    } else {
      for chunk in T3BrowserInput.textChunks(text) { send(.text(chunk)) }
    }
  }
  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    marked = NSMutableAttributedString(
      string: (string as? NSAttributedString)?.string ?? (string as? String ?? ""))
    marked.addAttributes(
      [
        .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.textBackgroundColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ], range: NSRange(location: 0, length: marked.length))
    markedSelection = selectedRange
    needsDisplay = true
  }
  func unmarkText() {
    marked = NSMutableAttributedString(string: "")
    needsDisplay = true
  }
  func hasMarkedText() -> Bool { marked.length > 0 }
  func markedRange() -> NSRange {
    hasMarkedText()
      ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
  }
  func selectedRange() -> NSRange { markedSelection }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    guard range.location != NSNotFound, NSMaxRange(range) <= marked.length else { return nil }
    actualRange?.pointee = range
    return marked.attributedSubstring(from: range)
  }
  func characterIndex(for point: NSPoint) -> Int { 0 }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    actualRange?.pointee = markedRange()
    let local = NSRect(
      x: lastPoint.x, y: min(bounds.height - 24, lastPoint.y + 24), width: 1, height: 22)
    return window?.convertToScreen(convert(local, to: nil)) ?? .zero
  }
  override func doCommand(by selector: Selector) {
    // 输入法处理期间，提交/取消由 interpretKeyEvents 决定，不把预编辑字符串提前发送。
    if selector == #selector(NSResponder.cancelOperation(_:)) { unmarkText() }
  }
}

import WebKit

/// 接入现有 MessageSelectionReader，公式正文仍可框选后引用，不触碰系统剪贴板。
final class MathMessageWebView: WKWebView {
  var messageSelection = ""

  override func accessibilitySelectedText() -> String? {
    messageSelection.isEmpty ? nil : messageSelection
  }
}

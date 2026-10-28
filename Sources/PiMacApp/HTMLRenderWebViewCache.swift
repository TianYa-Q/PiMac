import WebKit

/// 仅保留最近卸载的少量页面；不复用正在显示的视图，也不长期保活 WebKit 进程。
@MainActor
final class HTMLRenderWebViewCache {
  static let shared = HTMLRenderWebViewCache()
  private let capacity: Int
  private let lifetime: TimeInterval
  private var entries: [(String, Entry)] = []

  final class Entry: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let dark: Bool
    let height: Double?
    var valid = true

    init(view: WKWebView, dark: Bool, height: Double?) {
      self.view = view
      self.dark = dark
      self.height = height
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { valid = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      valid = false
    }
    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      valid = false
    }
    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      // 页面暂存时仍维持原有导航边界，不能因解绑宿主而放行跳转。
      let url = action.request.url?.absoluteString.components(separatedBy: "#").first
      decisionHandler(["about:blank", "about:srcdoc"].contains(url ?? "") ? .allow : .cancel)
    }
  }

  init(capacity: Int = 3, lifetime: TimeInterval = 120) {
    self.capacity = capacity
    self.lifetime = lifetime
  }

  func take(key: String) -> Entry? {
    guard let index = entries.firstIndex(where: { $0.0 == key }) else { return nil }
    let entry = entries.remove(at: index).1
    entry.view.navigationDelegate = nil
    return entry.valid ? entry : nil
  }

  func store(_ view: WKWebView, key: String, dark: Bool, height: Double?) {
    entries.removeAll { $0.0 == key }
    let entry = Entry(view: view, dark: dark, height: height)
    view.navigationDelegate = entry
    entries.append((key, entry))
    while entries.count > capacity { entries.removeFirst().1.view.stopLoading() }
    // 超时主动释放，而不是等下次访问才清理；避免闲置会话持续占用网页进程。
    DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self, weak entry] in
      guard let self, let entry else { return }
      self.entries.removeAll { $0.1 === entry }
    }
  }
}

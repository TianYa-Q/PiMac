import AppKit
import SwiftUI
import WebKit

/// 在 Markdown 解释反斜杠前提取公式；代码跨度必须先匹配，不能把示例代码排成公式。
enum MarkdownMath {
  private static let tokens = try! NSRegularExpression(
    pattern:
      #"(`+)[\s\S]*?\1|(?<!\\)\\\[([\s\S]*?)\\\]|(?<!\\)\\\(([\s\S]*?)\\\)|(?<![\\$])\$\$([\s\S]*?)\$\$|(?<![\\$])\$(?!\s)([^\n$]*?\S)\$(?![\d$])"#
  )

  static func containsMath(_ blocks: [MarkdownBlock]) -> Bool {
    blocks.contains { block in
      switch block {
      case .code(let language, _): return language == "math" || language == "latex"
      case .paragraph(let text), .heading(_, let text), .quote(let text):
        return hasFormula(text)
      case .list(_, _, let items): return items.contains(where: hasFormula)
      default: return false
      }
    }
  }

  private static func hasFormula(_ text: String) -> Bool {
    tokens.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains {
      $0.range(at: 1).location == NSNotFound
    }
  }

  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  static func inlineHTML(_ text: String) -> String {
    let source = text as NSString
    var cursor = 0
    var protected = ""
    var formulas: [(String, String)] = []
    // 占位后整体解析 Markdown，保留 **公式 $x$** 等跨公式的强调语义。
    let prefix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    for match in tokens.matches(in: text, range: NSRange(location: 0, length: source.length)) {
      protected += source.substring(
        with: NSRange(location: cursor, length: match.range.location - cursor))
      if match.range(at: 1).location != NSNotFound {
        protected += source.substring(with: match.range)
      } else {
        let group = (2...5).first { match.range(at: $0).location != NSNotFound }!
        let display = group == 2 || group == 4
        let tag = display ? "div" : "span"
        let token = "\(prefix)MATH\(formulas.count)END"
        protected += token
        formulas.append(
          (
            token,
            "<\(tag) class=\"math\" data-display=\"\(display)\" data-tex=\"\(escape(source.substring(with: match.range(at: group))))\">\(escape(source.substring(with: match.range)))</\(tag)>"
          ))
      }
      cursor = NSMaxRange(match.range)
    }
    protected += source.substring(from: cursor)
    return proseHTML(protected, formulas: formulas)
  }

  private static func proseHTML(_ text: String, formulas: [(String, String)]) -> String {
    let value = MarkdownInlineCache.attributedString(for: text)
    return value.runs.map { run in
      var html = escape(String(value[run.range].characters)).replacingOccurrences(
        of: "\n", with: "<br>")
      for (token, formula) in formulas {
        html = html.replacingOccurrences(of: token, with: formula)
      }
      let intent = run.inlinePresentationIntent ?? []
      if intent.contains(.code) { html = "<code>\(html)</code>" }
      if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
      if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
      if intent.contains(.strikethrough) { html = "<del>\(html)</del>" }
      if let link = run.link, ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "")
      {
        html = "<a href=\"\(escape(link.absoluteString))\">\(html)</a>"
      }
      return html
    }.joined()
  }

  static func bodyHTML(_ blocks: [MarkdownBlock]) -> String {
    blocks.map { block in
      switch block {
      case .paragraph(let text): return "<section>\(inlineHTML(text))</section>"
      case .heading(let level, let text): return "<h\(level)>\(inlineHTML(text))</h\(level)>"
      case .quote(let text): return "<blockquote>\(inlineHTML(text))</blockquote>"
      case .list(let ordered, let start, let items):
        let tag = ordered ? "ol" : "ul"
        return "<\(tag) start=\"\(start)\">" + items.map { "<li>\(inlineHTML($0))</li>" }.joined()
          + "</\(tag)>"
      case .code(let language, let text):
        if language == "math" || language == "latex" {
          return
            "<div class=\"math\" data-display=\"true\" data-tex=\"\(escape(text))\">\(escape(text))</div>"
        }
        return "<pre><code>\(escape(text))</code></pre>"
      case .divider: return "<hr>"
      case .table: return ""  // 表格继续由原生布局负责。
      }
    }.joined()
  }

  static func page(blocks: [MarkdownBlock], fontSize: CGFloat, dark: Bool, id: String) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' pimac-math:; style-src 'unsafe-inline' pimac-math:; font-src pimac-math:; img-src 'none'; connect-src 'none'">
    <link rel="stylesheet" href="katex.min.css"><script src="katex.min.js"></script>
    <style>
    :root { color-scheme: \(dark ? "dark" : "light"); }
    html,body { margin:0; padding:0; background:transparent; }
    body { color:\(dark ? "#e3e3e7" : "#242426"); font: \(fontSize)px -apple-system; line-height:1.5; overflow-wrap:anywhere; }
    section,blockquote,pre,ul,ol,h1,h2,h3,h4,h5,h6 { margin:0 0 12px; }
    main>:last-child { margin-bottom:0; } h1 {font-size:1.8em} h2 {font-size:1.5em} h3 {font-size:1.2em}
    blockquote { border-left:3px solid #888; padding-left:10px; opacity:.8; }
    pre {white-space:pre-wrap} code {font-family:ui-monospace,monospace} a {color:#409cff}
    .math[data-display="true"] {overflow-x:auto; overflow-y:hidden; margin:12px 0; padding:4px 0;}
    .katex-display {margin:0; text-align:left;} .katex {font-size:1.15em;} .math-error {font-family:ui-monospace,monospace; white-space:pre-wrap;}
    </style></head><body><main id="content">\(bodyHTML(blocks))</main>
    <script>
    let activeID = '\(id)';
    const report = () => window.webkit.messageHandlers.mathSize.postMessage({id:activeID,height:document.body.getBoundingClientRect().height});
    window.updateMath = (html, id) => {
      activeID = id; window.mathReady = false;
      if (html !== null) document.getElementById('content').innerHTML = html;
      for (const element of document.querySelectorAll('.math')) {
        const fallback = element.dataset.source || element.textContent;
        element.dataset.source = fallback;
        try {
          katex.render(element.dataset.tex, element, {displayMode:element.dataset.display==='true',
            output:'htmlAndMathml', throwOnError:true, trust:false, strict:'ignore', maxSize:20, maxExpand:1000});
        } catch (error) { element.textContent=fallback; element.classList.add('math-error'); element.title='公式无法排版，保留原文'; }
      }
      document.fonts.ready.then(() => {
        if (activeID !== id) return;
        window.mathReady = true; report();
      });
    };
    document.addEventListener('selectionchange', () => {
      window.webkit.messageHandlers.mathSelection.postMessage({id:activeID,text:window.getSelection().toString()});
    });
    new ResizeObserver(report).observe(document.body);
    window.updateMath(null, activeID);
    </script></body></html>
    """
  }
}

/// 只有包含公式的连续正文使用离线 WebKit；普通消息仍走原有 TextKit，避免全局引入网页开销。
struct MarkdownMathView: View {
  let blocks: [MarkdownBlock]
  let textStyle: NSFont.TextStyle
  @Environment(\.colorScheme) private var colorScheme
  @State private var height: CGFloat = 120

  var body: some View {
    MathWebContent(
      blocks: blocks, fontSize: NSFont.preferredFont(forTextStyle: textStyle).pointSize,
      dark: colorScheme == .dark, height: $height
    )
    .frame(height: height)
  }
}

private struct MathWebContent: NSViewRepresentable {
  let blocks: [MarkdownBlock]
  let fontSize: CGFloat
  let dark: Bool
  @Binding var height: CGFloat

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.setURLSchemeHandler(MathResourceHandler(), forURLScheme: "pimac-math")
    configuration.userContentController.add(context.coordinator, name: "mathSize")
    configuration.userContentController.add(context.coordinator, name: "mathSelection")
    let view = MathMessageWebView(frame: .zero, configuration: configuration)
    view.setValue(false, forKey: "drawsBackground")
    view.navigationDelegate = context.coordinator
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    context.coordinator.onHeight = { height = $0 }
    let key = "\(fontSize):\(dark):\(blocks)"
    guard context.coordinator.key != key else { return }
    let coordinator = context.coordinator
    coordinator.key = key
    (view as? MathMessageWebView)?.messageSelection = ""
    let id = UUID().uuidString
    coordinator.id = id
    coordinator.html = MarkdownMath.bodyHTML(blocks)
    let appearance = "\(fontSize):\(dark)"
    if coordinator.appearance == appearance {
      if coordinator.loaded { coordinator.updateContent(view) }
    } else {
      coordinator.appearance = appearance
      coordinator.loaded = false
      let base = URL(string: "pimac-math://bundle/")!
      view.loadHTMLString(
        MarkdownMath.page(blocks: blocks, fontSize: fontSize, dark: dark, id: id), baseURL: base)
    }
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    view.stopLoading()
    view.configuration.userContentController.removeScriptMessageHandler(forName: "mathSize")
    view.configuration.userContentController.removeScriptMessageHandler(forName: "mathSelection")
    coordinator.onHeight = nil
  }

  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var key = ""
    var id = ""
    var html = ""
    var appearance = ""
    var loaded = false
    var onHeight: ((CGFloat) -> Void)?

    func updateContent(_ view: WKWebView) {
      // 通过参数而非拼接脚本传正文；流式更新复用页面，避免反复重载字体和闪白。
      view.callAsyncJavaScript(
        "window.updateMath(html, id)", arguments: ["html": html, "id": id], in: nil, in: .page
      ) { _ in }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      loaded = true
      updateContent(webView)
    }

    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      // 旧页面的异步字体/尺寸回调不能覆盖新一轮流式正文的高度。
      guard let body = message.body as? [String: Any], body["id"] as? String == id else { return }
      if message.name == "mathSelection" {
        (message.webView as? MathMessageWebView)?.messageSelection = body["text"] as? String ?? ""
      } else if let number = body["height"] as? Double, number.isFinite, number > 0 {
        onHeight?(ceil(number))
      }
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      if navigationAction.navigationType == .linkActivated {
        if let url = navigationAction.request.url,
          ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
        {
          NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
      } else {
        let url = navigationAction.request.url
        decisionHandler(
          url?.scheme == "about" || url?.absoluteString == "pimac-math://bundle/" ? .allow : .cancel
        )
      }
    }
  }
}

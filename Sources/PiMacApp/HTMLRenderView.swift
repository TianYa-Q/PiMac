import AppKit
import SwiftUI
import WebKit

private struct HTMLRenderViewportHeightKey: EnvironmentKey {
  static let defaultValue: Double = 600
}

extension EnvironmentValues {
  var htmlRenderViewportHeight: Double {
    get { self[HTMLRenderViewportHeightKey.self] }
    set { self[HTMLRenderViewportHeightKey.self] = newValue }
  }
}

struct HTMLRenderView: View {
  let reference: T3HTMLRender
  let document: String?
  let failure: String?
  @EnvironmentObject private var workspace: WorkspaceModel
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.htmlRenderViewportHeight) private var viewportHeight
  @State private var retriedDocument: String?
  @State private var error: String?
  @State private var contentHeight: Double?
  @State private var frameWidth: Double = 728
  @State private var externalLink: URL?

  private var previewHeight: Double {
    reference.previewHeight(
      width: frameWidth, contentHeight: contentHeight, viewportHeight: viewportHeight)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let html = retriedDocument ?? document {
        GeometryReader { geometry in
          HTMLRenderWebView(
            html: html, dark: colorScheme == .dark,
            onHeight: { contentHeight = $0 }, onError: { error = $0 },
            onLink: { externalLink = $0 }
          )
          .accessibilityLabel(reference.title)
          .onAppear { frameWidth = geometry.size.width }
          .onChange(of: geometry.size.width) { _, width in frameWidth = width }
        }
        .frame(height: previewHeight)
      } else if error == nil && failure == nil {
        // 首次快照可能比附件先到；保留页面几何，不用转圈和收缩/膨胀打断阅读。
        Color.clear
          .frame(height: previewHeight)
      }
      if let error = error ?? (retriedDocument == nil ? failure : nil) {
        HStack {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
          Button("重试") {
            Task {
              do {
                retriedDocument = try await workspace.server.htmlRenderDocument(reference)
                self.error = nil
              } catch {
                self.error = "HTML 页面加载失败"
              }
            }
          }
        }
        .font(.caption)
      }
    }
    .frame(maxWidth: 728, alignment: .leading)
    .confirmationDialog(
      "打开外部链接？",
      isPresented: Binding(
        get: { externalLink != nil }, set: { if !$0 { externalLink = nil } }
      )
    ) {
      if let externalLink {
        Button("在浏览器中打开") {
          NSWorkspace.shared.open(externalLink)
          self.externalLink = nil
        }
      }
      Button("取消", role: .cancel) { externalLink = nil }
    } message: {
      Text(externalLink?.absoluteString ?? "")
    }
  }
}

/// HTML 在无同源权限的 iframe 中执行，宿主不提供文件、凭据或任意原生调用桥。
struct HTMLRenderWebView: NSViewRepresentable {
  let html: String
  let dark: Bool
  let onHeight: (Double) -> Void
  let onError: (String) -> Void
  let onLink: (URL) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(context.coordinator, name: "renderEvent")
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    context.coordinator.observeWheel(in: view)
    view.setValue(false, forKey: "drawsBackground")
    view.loadHTMLString(Self.document(html: html, dark: dark), baseURL: nil)
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    context.coordinator.parent = self
    if context.coordinator.html != html {
      context.coordinator.html = html
      view.loadHTMLString(Self.document(html: html, dark: dark), baseURL: nil)
    } else if context.coordinator.dark != dark {
      view.evaluateJavaScript("window.setRenderTheme(\(Self.themeJSON(dark: dark)))")
    }
    context.coordinator.dark = dark
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    coordinator.stopObservingWheel()
    view.stopLoading()
    view.navigationDelegate = nil
    view.configuration.userContentController.removeScriptMessageHandler(forName: "renderEvent")
  }

  private static func json(_ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    // 避免页面内容里的 </script> 提前结束宿主脚本；字符串始终由 JSON 编码。
    return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
  }

  static func themeJSON(dark: Bool) -> String {
    // 使用当前原生配色，页面底色与会话区一致；不依赖 WebKit 进程自己的系统主题。
    func color(_ value: NSColor) -> String {
      var result = "#000000"
      NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
        if let rgb = value.usingColorSpace(.deviceRGB) {
          result = String(
            format: "#%02x%02x%02x", Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
        }
      }
      return result
    }
    let background = color(.windowBackgroundColor)
    let foreground = color(.labelColor)
    let muted = dark ? "#2b2d31" : "#f3f4f6"
    let secondary = dark ? "#a1a1aa" : "#6b7280"
    var variables: [String: String] = [
      "--background": background, "--foreground": foreground,
      "--muted": muted, "--muted-foreground": secondary,
      "--border": dark ? "#3b3d42" : "#e5e7eb", "--input": muted,
      "--ring": "#3b82f6", "--primary": "#3b82f6", "--primary-foreground": "#ffffff",
      "--accent": "#3b82f6", "--accent-foreground": foreground,
      "--accent-surface": dark ? "#25334c" : "#eff6ff",
      "--accent-surface-foreground": foreground,
      "--radius": "8px", "--font-sans": "-apple-system, BlinkMacSystemFont, sans-serif",
      "--font-mono": "ui-monospace, SFMono-Regular, monospace",
    ]
    for key in ["card", "popover", "secondary", "code-background"] {
      variables["--\(key)"] = muted
    }
    for key in ["card-foreground", "popover-foreground", "secondary-foreground", "code-foreground"]
    {
      variables["--\(key)"] = foreground
    }
    for (key, color) in [
      ("success", "#22c55e"), ("warning", "#f59e0b"),
      ("destructive", "#ef4444"), ("info", "#38bdf8"),
    ] {
      variables["--\(key)"] = color
      variables["--\(key)-foreground"] = foreground
      variables["--\(key)-surface"] = muted
    }
    for (index, color) in ["#3b82f6", "#22c55e", "#f59e0b", "#a78bfa", "#f472b6", "#38bdf8"]
      .enumerated()
    {
      variables["--chart-\(index + 1)"] = color
    }
    return json(["appearance": dark ? "dark" : "light", "variables": variables])
  }

  static func document(html: String, dark: Bool) -> String {
    // iframe 内仅报告滚动边界，不提供原生权限。也考虑页面里的可滚动表格/列表。
    let scrollProbe = """
      <script>(function(){let target=null;function report(){
        let el=target;while(el&&el!==document.body&&el!==document.documentElement){
          const style=getComputedStyle(el);if(/auto|scroll/.test(style.overflowY)&&el.scrollHeight>el.clientHeight+1)break;el=el.parentElement;
        }
        if(!el||el===document.body||el===document.documentElement)el=document.scrollingElement||document.documentElement;
        parent.postMessage({jsonrpc:'2.0',method:'pi/scroll-state',params:{top:el.scrollTop,height:el.scrollHeight,viewport:el.clientHeight}},'*');
      }document.addEventListener('mouseover',e=>{target=e.target instanceof Element?e.target:null;report();},true);
      document.addEventListener('scroll',report,true);window.addEventListener('resize',report);window.addEventListener('load',report);
      new ResizeObserver(report).observe(document.documentElement);report();})();</script>
      """
    return """
      <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
      <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}iframe{width:100%;height:100%;border:0;display:block}</style></head>
      <body><iframe id="page" sandbox="allow-scripts" referrerpolicy="no-referrer"></iframe><script>
      const page=document.getElementById('page');let theme=\(themeJSON(dark: dark));
      window.setRenderTheme=function(t){theme=t;page.contentWindow.postMessage({jsonrpc:'2.0',method:'ui/notifications/host-context-changed',params:{theme:t.appearance,styles:{variables:t.variables}}},'*');};
      page.addEventListener('load',()=>window.setRenderTheme(theme));
      window.addEventListener('message',e=>{if(e.source!==page.contentWindow)return;
        const d=e.data;if(!d||d.jsonrpc!=='2.0'||!d.params)return;
        if(d.method==='ui/notifications/size-changed'&&Number.isFinite(d.params.height))
          window.webkit.messageHandlers.renderEvent.postMessage({height:d.params.height});
        if(d.method==='ui/open-link'&&typeof d.params.url==='string')
          window.webkit.messageHandlers.renderEvent.postMessage({url:d.params.url});
        if(d.method==='pi/scroll-state')
          window.webkit.messageHandlers.renderEvent.postMessage({scroll:d.params});
      });page.srcdoc=\(json(html + scrollProbe));
      </script></body></html>
      """
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var parent: HTMLRenderWebView
    var html: String
    var dark: Bool
    var scrollState = HTMLRenderScrollState()
    private weak var webView: WKWebView?
    private var wheelMonitor: Any?

    func observeWheel(in view: WKWebView) {
      webView = view
      wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
        [weak self, weak view] event in
        guard let self, let view, event.window === view.window,
          view.bounds.contains(view.convert(event.locationInWindow, from: nil)),
          self.routeWheel(event)
        else { return event }
        return nil
      }
    }

    func stopObservingWheel() {
      if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
      wheelMonitor = nil
      webView = nil
    }

    /// 返回 true 表示已转交会话；触控板惯性由后续事件驱动，精确像素不做额外缩放。
    func routeWheel(_ event: NSEvent) -> Bool {
      guard
        scrollState.routesToConversation(
          deltaY: event.scrollingDeltaY, deltaX: event.scrollingDeltaX),
        let scroll = webView?.enclosingScrollView
      else { return false }
      NotificationCenter.default.post(
        name: NSScrollView.willStartLiveScrollNotification,
        object: scroll, userInfo: ["userGesture": true])
      // 不再把事件送回 NSScrollView 的命中/嵌套滚动分发，避免再次落到 WebKit。
      // 直接更新外层 clip，鼠标按行缩放、触控板按精确像素滚动，并遵守真实内容边界。
      let clip = scroll.contentView
      let scale = event.hasPreciseScrollingDeltas ? 1 : scroll.verticalLineScroll
      var bounds = clip.bounds
      bounds.origin.y += (clip.isFlipped ? -1 : 1) * event.scrollingDeltaY * scale
      clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
      scroll.reflectScrolledClipView(clip)
      NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
      return true
    }

    deinit {
      if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
    }

    init(parent: HTMLRenderWebView) {
      self.parent = parent
      html = parent.html
      dark = parent.dark
    }

    func userContentController(
      _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard message.frameInfo.isMainFrame, let data = message.body as? [String: Any] else { return }
      if let metrics = data["scroll"] as? [String: Double],
        let top = metrics["top"], let height = metrics["height"],
        let viewport = metrics["viewport"],
        let state = HTMLRenderScrollState(top: top, height: height, viewport: viewport)
      {
        scrollState = state
      }
      if let height = data["height"] as? Double, height.isFinite, height > 0 {
        parent.onHeight(min(2000, max(80, height)))
      }
      if let text = data["url"] as? String, text.count <= 8192, let url = URL(string: text),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
      {
        parent.onLink(url)
      }
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      // 禁止页面跳转到文件、自定义协议或替换宿主；外链只经用户确认交给系统浏览器。
      let document = action.request.url?.absoluteString.components(separatedBy: "#").first
      let allowed = ["about:blank", "about:srcdoc"].contains(document ?? "")
      decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      parent.onError("HTML 页面显示失败")
    }
    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      parent.onError("HTML 页面显示失败")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      parent.onError("HTML 页面进程已退出，请重试")
    }
  }
}

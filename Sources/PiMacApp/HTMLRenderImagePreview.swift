import Foundation
import SwiftUI

/// 图片放大仅接受网页本已可加载的图片源，不把 file URL、自定义协议或宿主凭据交给网页。
struct HTMLRenderImageSource: Identifiable, Equatable {
  static let maximumLength = 16 * 1024 * 1024
  let source: String
  var id: String { source }

  init?(_ source: String) {
    guard !source.isEmpty, source.utf8.count <= Self.maximumLength else { return nil }
    if source.hasPrefix("data:") {
      guard let comma = source.firstIndex(of: ","), source.index(after: comma) < source.endIndex
      else { return nil }
      let header = source[..<comma].lowercased()
      let mime = header.dropFirst(5).split(separator: ";", maxSplits: 1).first.map(String.init)
      guard let mime,
        ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/svg+xml"]
          .contains(mime)
      else { return nil }
    } else {
      guard source.utf8.count <= 8192, let url = URL(string: source),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
        let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
      else { return nil }
    }
    self.source = source
  }

  var document: String {
    let data = try! JSONSerialization.data(withJSONObject: source, options: [.fragmentsAllowed])
    let encoded = String(decoding: data, as: UTF8.self)
      .replacingOccurrences(of: "<", with: "\\u003c")
    return """
      <!doctype html><html><head><style>
      html,body{margin:0;width:100%;height:100%;background:var(--background);overflow:auto;overscroll-behavior:contain}
      body{display:flex;align-items:center;justify-content:center}img{max-width:100%;max-height:100%;object-fit:contain}
      </style></head><body><img id="image" alt="放大预览"><script>
      const image=document.getElementById('image');
      image.onerror=()=>parent.postMessage({jsonrpc:'2.0',method:'pi/image-load-failed',params:{}},'*');
      image.src=\(encoded);</script></body></html>
      """
  }
}

struct HTMLRenderImagePreview: View {
  let image: HTMLRenderImageSource
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("图片预览", systemImage: "photo")
        Text("双指缩放，滚动查看").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      .padding(12)
      Divider()
      HTMLRenderWebView(
        html: image.document, dark: colorScheme == .dark,
        onHeight: { _ in }, onError: { error = $0 }, onLink: { _ in },
        allowsMagnification: true
      )
      .accessibilityLabel("可缩放的 HTML 图片预览")
      if let error { Text(error).font(.caption).foregroundStyle(.secondary).padding(8) }
    }
    .frame(minWidth: 640, idealWidth: 960, minHeight: 480, idealHeight: 720)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

import Foundation
import WebKit

/// loadHTMLString 不授予 file 目录读取权；专用 scheme 只提供打包的 KaTeX，绝不暴露工作区文件。
final class MathResourceHandler: NSObject, WKURLSchemeHandler {
  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    do {
      guard let url = urlSchemeTask.request.url, url.host == "bundle" else {
        throw URLError(.badURL)
      }
      let base = Bundle.module.resourceURL!.appendingPathComponent("KaTeX").standardizedFileURL
      let resource = base.appendingPathComponent(url.path).standardizedFileURL
      guard resource.path.hasPrefix(base.path + "/"),
        ["katex.min.js", "katex.min.css"].contains(resource.lastPathComponent)
          || (resource.deletingLastPathComponent().lastPathComponent == "fonts"
            && ["woff2", "woff", "ttf"].contains(resource.pathExtension))
      else { throw URLError(.noPermissionsToReadFile) }
      let data = try Data(contentsOf: resource)
      let mime: String
      switch resource.pathExtension {
      case "js": mime = "application/javascript"
      case "css": mime = "text/css"
      case "woff2": mime = "font/woff2"
      case "woff": mime = "font/woff"
      default: mime = "font/ttf"
      }
      urlSchemeTask.didReceive(
        URLResponse(
          url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
      urlSchemeTask.didReceive(data)
      urlSchemeTask.didFinish()
    } catch {
      urlSchemeTask.didFailWithError(error)
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

import Foundation

/// 只适配原生 URL；路径解析、编码和文件类型由固定版本的 T3 Code 客户端模块处理。
enum T3ReplyDocumentLinks {
  static func href(for url: URL) -> String? {
    guard url.host == nil || url.host == "", url.query == nil,
      url.scheme == nil || url.scheme == "file"
    else { return nil }
    guard url.isFileURL else { return url.relativeString }
    // JavaScriptCore 没有浏览器 URL 全局对象；Foundation 仅拆出编码路径，不能提前解码两次。
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    return components.percentEncodedPath
      + (components.percentEncodedFragment.map { "#" + $0 } ?? "")
  }
}

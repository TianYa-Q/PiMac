import Foundation

/// Documents are resolved by the server in the thread's workspace, not by Launch Services.
enum T3ReplyDocumentLinks {
  static func path(for url: URL) -> String? {
    guard url.host == nil || url.host == "", url.query == nil,
      url.scheme == nil || url.scheme == "file"
    else { return nil }
    // A fragment belongs to the viewer, not to the filesystem path.
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    components.fragment = nil
    guard let fileURL = components.url else { return nil }
    let path = fileURL.isFileURL ? fileURL.path : fileURL.relativeString.removingPercentEncoding ?? fileURL.relativeString
    guard !path.isEmpty, path.utf8.count <= 1024, !path.contains("\0"),
      ["html", "htm", "pdf"].contains((path as NSString).pathExtension.lowercased())
    else { return nil }
    return path
  }
}

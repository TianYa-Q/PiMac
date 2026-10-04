import Foundation

/// Decode at the trust boundary. Missing optional strings are compatible with old clients;
/// explicitly wrong types are not silently converted into empty permission prompts.
enum ExtensionDialogRequest {
  static func parse(_ event: PiRPCClient.JSON) -> ExtensionDialog? {
    guard let id = event["id"] as? String, !id.isEmpty, id.utf8.count <= 1024,
      let method = event["method"] as? String,
      ["title", "message", "prefill", "placeholder"].allSatisfy({
        event[$0] == nil || event[$0] is String
      })
    else { return nil }
    let title = event["title"] as? String ?? "Pi 扩展"
    let kind: ExtensionDialogKind
    switch method {
    case "select":
      guard let options = event["options"] as? [String] else { return nil }
      kind = .select(options: options)
    case "confirm":
      kind = .confirm(message: event["message"] as? String ?? "")
    case "input", "editor":
      kind = .input(
        initialText: event["prefill"] as? String ?? "",
        placeholder: event["placeholder"] as? String ?? "", multiline: method == "editor")
    default:
      return nil
    }
    let dialog = ExtensionDialog(id: id, title: title, kind: kind)
    return ExtensionDialogLimits.accepts(dialog) ? dialog : nil
  }
}

enum ExtensionStatusLimits {
  static let maximumEntries = 64
  static let maximumKeyBytes = 256
  static let maximumTextBytes = 16 * 1024
}

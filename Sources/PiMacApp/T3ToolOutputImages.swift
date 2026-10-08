import Foundation

/// Mirrors upstream toolOutputImages; accepted image order is the signed asset index.
enum T3ToolOutputImages {
  static func mimeTypes(_ output: Any?) -> [String] {
    let blocks: [Any]
    if let array = output as? [Any] {
      blocks = array
    } else if let object = output as? [String: Any], let content = object["content"] as? [Any] {
      blocks = content
    } else {
      blocks = output.map { [$0] } ?? []
    }
    return Array(
      blocks.compactMap { block -> String? in
        guard let block = block as? [String: Any], block["type"] as? String == "image" else {
          return nil
        }
        let mime: String?
        if let source = block["source"] as? [String: Any] {
          guard source["type"] as? String == "base64" else { return nil }
          mime = source["media_type"] as? String
        } else {
          mime = block["mimeType"] as? String
        }
        guard let mime = mime?.lowercased(), T3ToolImageCache.fileExtension(mime) != nil else {
          return nil
        }
        return mime
      }.prefix(8))
  }
}

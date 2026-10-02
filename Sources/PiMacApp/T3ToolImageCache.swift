import CryptoKit
import Foundation
import ImageIO

/// Downloaded native T3 assets are cached locally; binary data never becomes chat text.
enum T3ToolImageCache {
  static let maxBytes = 20 * 1024 * 1024

  static func fileExtension(_ mimeType: String) -> String? {
    switch mimeType {
    case "image/png": "png"
    case "image/jpeg": "jpg"
    case "image/webp": "webp"
    case "image/gif": "gif"
    default: nil
    }
  }

  private static func url(key: String, mimeType: String) -> URL? {
    guard let ext = fileExtension(mimeType),
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return nil }
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return support.appendingPathComponent("PiMac/T3ToolImages", isDirectory: true)
      .appendingPathComponent("\(digest).\(ext)")
  }

  static func cached(key: String, mimeType: String, size: Int) -> PromptAttachment? {
    guard size > 0, size <= maxBytes, let file = url(key: key, mimeType: mimeType),
      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
      values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == size
    else { return nil }
    return PromptAttachment(url: file, mimeType: mimeType)
  }

  static func store(_ data: Data, key: String, mimeType: String) throws -> PromptAttachment {
    guard !data.isEmpty, data.count <= maxBytes, let file = url(key: key, mimeType: mimeType),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 64_000_000
    else { throw T3DesktopClient.ClientError.rejected }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return PromptAttachment(url: file, mimeType: mimeType)
  }
}

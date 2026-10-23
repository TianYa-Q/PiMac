import Foundation

/// 只跨线程传递不可变的类型化数据，不把 Any 字典带出主线程隔离域。
struct PromptImagePayload: Sendable {
  let name: String
  let mimeType: String
  let sizeBytes: Int
  let dataURL: String

  var json: [String: Any] {
    [
      "type": "image", "name": name, "mimeType": mimeType,
      "sizeBytes": sizeBytes, "dataUrl": dataURL,
    ]
  }

  static func encode(_ attachments: [PromptAttachment]) async throws -> [Self] {
    let images = attachments.filter(\.isImage)
    guard !images.isEmpty else { return [] }
    // Task {} 继承 MainActor；必须显式离开，避免文件读取和 Base64 编码阻塞输入及滚动。
    let task = Task.detached(priority: .userInitiated) {
      try images.map { attachment in
        try Task.checkCancellation()
        let size = try attachment.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size > 0, size <= 8 * 1024 * 1024,
          let mime = attachment.mimeType
        else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: attachment.url)
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else {
          throw CocoaError(.fileReadTooLarge)
        }
        return Self(
          name: attachment.url.lastPathComponent, mimeType: mime,
          sizeBytes: data.count, dataURL: "data:\(mime);base64,\(data.base64EncodedString())")
      }
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}

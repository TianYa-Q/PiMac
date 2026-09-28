import Foundation

/// Local diagnostic timeline. Never include message text, credentials or Telegram API URLs.
@MainActor
enum TelegramDeliveryLog {
  nonisolated static let url = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/PiMac/Logs/telegram-delivery.log")
  private static let maxBytes: UInt64 = 1_000_000
  private static let formatter = ISO8601DateFormatter()

  static func record(
    _ event: String, task: UUID, sessionPath: String,
    details: String = "", destination: URL = url
  ) {
    let session = URL(fileURLWithPath: sessionPath).deletingPathExtension().lastPathComponent
    let line =
      "\(formatter.string(from: .now)) task=\(task.uuidString) session=\(session) \(event) \(details)\n"
    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      if let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size]
        as? NSNumber,
        size.uint64Value >= maxBytes
      {
        let old = destination.appendingPathExtension("old")
        try? FileManager.default.removeItem(at: old)
        try FileManager.default.moveItem(at: destination, to: old)
      }
      if !FileManager.default.fileExists(atPath: destination.path) {
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
      }
      let handle = try FileHandle(forWritingTo: destination)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(line.utf8))
    } catch {
      // Diagnostics must never prevent message delivery.
    }
  }
}

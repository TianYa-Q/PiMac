import Foundation

/// Errors are persisted even when the development reloader redirects stderr to /dev/null.
enum LidSleepDiagnostics {
  private static let lock = NSLock()

  static func record(_ message: String) {
    let entry = "\(ISO8601DateFormatter().string(from: .now)) \(message.prefix(8192))\n"
    NSLog("PiMac lid sleep: %@", message)
    lock.lock()
    defer { lock.unlock() }
    let folder = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/PiMac", isDirectory: true)
    let file = folder.appendingPathComponent("lid-sleep.log")
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      // Keep the troubleshooting log bounded. It never contains credentials or script source.
      let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber
      if (size?.intValue ?? 0) > 1_000_000 { try Data().write(to: file, options: .atomic) }
      if !FileManager.default.fileExists(atPath: file.path) {
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
      }
      let handle = try FileHandle(forWritingTo: file)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(entry.utf8))
    } catch {
      NSLog("PiMac lid sleep log failed: %@", error.localizedDescription)
    }
  }
}

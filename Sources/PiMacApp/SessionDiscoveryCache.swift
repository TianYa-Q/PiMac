import Foundation

/// Discovery is shared by the desktop and Telegram. Unchanged JSONL files should
/// not be decoded again just to display a list or resolve a session button.
final class SessionDiscoveryCache: @unchecked Sendable {
  static let shared = SessionDiscoveryCache()

  private struct Key: Hashable {
    let project: String
    let path: String
  }

  private struct Entry {
    let modifiedAt: Date
    let size: Int
    let item: SessionItem?
  }

  private let lock = NSLock()
  private var entries: [Key: Entry] = [:]

  func item(
    at url: URL, project: String, load: () -> SessionItem?
  ) -> SessionItem? {
    guard
      let before = try? url.resourceValues(forKeys: [
        .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
      ]), before.isRegularFile == true,
      let modifiedAt = before.contentModificationDate, let size = before.fileSize
    else { return nil }
    let key = Key(project: project, path: url.standardizedFileURL.path)
    lock.lock()
    let cached = entries[key]
    lock.unlock()
    if let cached, cached.modifiedAt == modifiedAt, cached.size == size {
      return cached.item
    }

    let item = load()
    // A running session may append while it is being read. Do not cache a
    // partial snapshot under the metadata of a newer file.
    let after = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [
      .contentModificationDateKey, .fileSizeKey,
    ])
    if after?.contentModificationDate == modifiedAt, after?.fileSize == size {
      lock.lock()
      if entries.count >= 4_096 { entries.removeAll(keepingCapacity: true) }
      entries[key] = Entry(modifiedAt: modifiedAt, size: size, item: item)
      lock.unlock()
    }
    return item
  }
}

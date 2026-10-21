import Foundation

/// Shared by desktop models; retains only complete disk snapshots, never live RPC context.
@MainActor
final class TranscriptCache {
  static let shared = TranscriptCache()

  private struct Snapshot {
    let key: String
    let entries: [ChatEntry]
    let cost: Int
  }

  private let maximumBytes: Int
  private let maximumSessions: Int
  private var snapshots: [String: Snapshot] = [:]
  private var recency: [String] = []
  private(set) var totalBytes = 0

  init(maximumBytes: Int = 32 * 1024 * 1024, maximumSessions: Int = 8) {
    self.maximumBytes = max(0, maximumBytes)
    self.maximumSessions = max(0, maximumSessions)
  }

  func entries(at path: String, key: String) -> [ChatEntry]? {
    guard let snapshot = snapshots[path] else { return nil }
    guard snapshot.key == key else {
      remove(path)
      return nil
    }
    touch(path)
    return snapshot.entries
  }

  func insert(_ entries: [ChatEntry], at path: String, key: String) {
    if snapshots[path]?.key == key {
      touch(path)
      return
    }
    remove(path)
    // 拆分累计表达式，避免发布环境 Swift 编译器在嵌套 reduce 中类型推断超时。
    let cost = entries.reduce(0) { total, entry in
      let textBytes = entry.id.utf8.count + entry.title.utf8.count + entry.text.utf8.count
      let toolBytes = (entry.toolInput?.utf8.count ?? 0) + (entry.diff?.utf8.count ?? 0)
      let attachmentBytes = entry.attachments.reduce(0) { bytes, attachment in
        bytes + 128 + attachment.url.absoluteString.utf8.count
      }
      return total + 256 + textBytes + toolBytes + attachmentBytes
    }
    guard !entries.isEmpty, cost <= maximumBytes, maximumSessions > 0 else { return }
    snapshots[path] = Snapshot(key: key, entries: entries, cost: cost)
    totalBytes += cost
    touch(path)
    while totalBytes > maximumBytes || snapshots.count > maximumSessions {
      guard let oldest = recency.first else { break }
      remove(oldest)
    }
  }

  private func touch(_ path: String) {
    recency.removeAll { $0 == path }
    recency.append(path)
  }

  private func remove(_ path: String) {
    if let snapshot = snapshots.removeValue(forKey: path) { totalBytes -= snapshot.cost }
    recency.removeAll { $0 == path }
  }
}

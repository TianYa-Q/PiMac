import CryptoKit
import Foundation

/// 附件不可变：按服务端地址和附件 ID 缓存，而不是按临时签名 URL 缓存。
/// 文件操作在独立 actor 上执行；缓存失败只影响加速，不掩盖真正的下载失败。
actor T3HTMLDocumentCache {
  static let shared = T3HTMLDocumentCache()
  static let maxDocumentBytes = 8 * 1024 * 1024
  private let directory: URL
  private let memoryLimit: Int
  private let diskLimit: Int
  private var memory: [String: String] = [:]
  private var recency: [String] = []
  private var memoryBytes = 0
  private var pending: [String: Task<String, Error>] = [:]

  private struct Record: Codable {
    let key: String
    let checksum: String
    let html: String
  }

  init(
    directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("PiMac/HTMLDocuments-v1", isDirectory: true),
    memoryLimit: Int = 16 * 1024 * 1024, diskLimit: Int = 128 * 1024 * 1024
  ) {
    self.directory = directory
    self.memoryLimit = memoryLimit
    self.diskLimit = diskLimit
  }

  static func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  func document(key: String, load: @escaping @Sendable () async throws -> String) async throws
    -> String
  {
    let id = Self.digest(key)
    if let html = memory[id] {
      recency.removeAll { $0 == id }
      recency.append(id)
      return html
    }
    if let task = pending[id] { return try await task.value }
    let task = Task {
      let file = directory.appendingPathComponent(id + ".json")
      if let values = try? file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ]),
        values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size <= Self.maxDocumentBytes * 6 + 1024,
        let data = try? Data(contentsOf: file),
        let record = try? JSONDecoder().decode(Record.self, from: data),
        record.key == id, !record.html.isEmpty,
        record.html.utf8.count <= Self.maxDocumentBytes,
        record.checksum == Self.digest(record.html)
      {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        remember(record.html, id: id)
        return record.html
      }
      // 丢失、损坏或版本不符都重新取真实附件；绝不缓存空页或下载错误。
      let html = try await load()
      try Task.checkCancellation()
      guard !html.isEmpty, html.utf8.count <= Self.maxDocumentBytes else {
        throw T3DesktopClient.ClientError.rejected
      }
      remember(html, id: id)
      do {
        let data = try JSONEncoder().encode(
          Record(key: id, checksum: Self.digest(html), html: html))
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if try reserve(bytes: data.count, replacing: file) {
          try data.write(to: file, options: .atomic)
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
      } catch {
        NSLog("HTML cache write failed: %@", String(describing: error))
      }
      return html
    }
    pending[id] = task
    defer { pending[id] = nil }
    return try await task.value
  }

  private func remember(_ html: String, id: String) {
    let size = html.utf8.count
    guard size <= memoryLimit else { return }
    while memoryBytes + size > memoryLimit, let oldest = recency.first {
      recency.removeFirst()
      memoryBytes -= memory.removeValue(forKey: oldest)?.utf8.count ?? 0
    }
    memory[id] = html
    memoryBytes += size
    recency.append(id)
  }

  /// 只整理自己的摘要命名普通文件；无法确认或无法移入废纸篓时停止写入，不能突破容量上限。
  private func reserve(bytes: Int, replacing target: URL) throws -> Bool {
    guard bytes <= diskLimit else { return false }
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]
    var entries: [(URL, Int, Date)] = []
    for file in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: Array(keys))
    {
      guard
        file.lastPathComponent.range(of: #"^[a-f0-9]{64}\.json$"#, options: .regularExpression)
          != nil
      else { continue }
      let values = try file.resourceValues(forKeys: keys)
      guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize
      else { continue }
      entries.append((file, size, values.contentModificationDate ?? .distantPast))
    }
    var total = entries.reduce(0) { $0 + ($1.0 == target ? 0 : $1.1) }
    for entry in entries.sorted(by: { $0.2 < $1.2 }) where entry.0 != target {
      if total + bytes <= diskLimit { break }
      try FileManager.default.trashItem(at: entry.0, resultingItemURL: nil)
      total -= entry.1
    }
    return total + bytes <= diskLimit
  }
}

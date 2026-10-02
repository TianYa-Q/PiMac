import Foundation

/// Text-only saved history. Never restores images, follows attachment/tool output
/// paths, changes a desktop tab, or starts a Pi process. Call off the main actor.
enum T3SessionFileReader {
  private final class Cached: NSObject {
    let messages: [ChatEntry]
    init(_ messages: [ChatEntry]) { self.messages = messages }
  }
  private static let cache: NSCache<NSString, Cached> = {
    let cache = NSCache<NSString, Cached>()
    cache.totalCostLimit = 32 * 1024 * 1024
    return cache
  }()

  static func read(path: String, project: String) throws -> [ChatEntry] {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let before = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ])
    guard before.isRegularFile == true, before.isSymbolicLink != true,
      let size = before.fileSize, size <= 64 * 1024 * 1024
    else { throw T3WorkspaceReadModel.ReadError.tooLarge }
    let key =
      "\(path)\u{0}\(project)\u{0}\(size)\u{0}\(before.contentModificationDate?.timeIntervalSince1970 ?? 0)"
      as NSString
    if let cached = cache.object(forKey: key) { return cached.messages }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count <= 64 * 1024 * 1024 else { throw T3WorkspaceReadModel.ReadError.tooLarge }
    let result = try parse(data, project: project)
    let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    if after.fileSize == before.fileSize,
      after.contentModificationDate == before.contentModificationDate
    {
      let cost = result.reduce(0) { $0 + $1.text.utf8.count + ($1.toolInput?.utf8.count ?? 0) }
      cache.setObject(Cached(result), forKey: key, cost: cost)
    }
    return result
  }

  static func parse(_ data: Data, project: String) throws -> [ChatEntry] {
    var records: [[String: Any]] = []
    for line in data.split(separator: 0x0A) {
      // Ignore a concurrent writer's unfinished final line, not a whole history.
      guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
      else { continue }
      records.append(record)
    }
    guard let header = records.first, header["type"] as? String == "session",
      let cwd = header["cwd"] as? String,
      URL(fileURLWithPath: cwd).standardizedFileURL.path
        == URL(fileURLWithPath: project).standardizedFileURL.path
    else { throw T3WorkspaceReadModel.ReadError.staleTarget }

    var parents: [String: String] = [:]
    var ids = Set<String>()
    for record in records {
      guard let id = record["id"] as? String else { continue }
      guard ids.insert(id).inserted else { throw T3WorkspaceReadModel.ReadError.staleTarget }
      if let parent = record["parentId"] as? String { parents[id] = parent }
    }
    var branch: Set<String>?
    if let leaf = records.last?["id"] as? String {
      var visible = Set<String>()
      var current: String? = leaf
      while let id = current, visible.insert(id).inserted { current = parents[id] }
      branch = visible
    }
    var entries: [ChatEntry] = []
    var byteCount = 0
    func append(_ entry: ChatEntry) throws {
      byteCount += entry.text.utf8.count + (entry.toolInput?.utf8.count ?? 0)
      guard byteCount <= 8 * 1024 * 1024, entries.count < 20000 else {
        throw T3WorkspaceReadModel.ReadError.tooLarge
      }
      entries.append(entry)
    }
    for (index, record) in records.enumerated() {
      if let branch {
        guard let id = record["id"] as? String, branch.contains(id) else { continue }
      }
      let id = record["id"] as? String ?? "record-\(index)"
      if record["type"] as? String == "compaction" {
        try append(
          ChatEntry(
            id: id, kind: .compaction, title: "上下文压缩",
            text: record["summary"] as? String ?? "", timestamp: date(record["timestamp"])))
        continue
      }
      guard record["type"] as? String == "message",
        let message = record["message"] as? [String: Any], let role = message["role"] as? String
      else { continue }
      let timestamp = date(message["timestamp"]) ?? date(record["timestamp"])
      let blocks = message["content"] as? [[String: Any]] ?? []
      func text() -> String {
        if let value = message["content"] as? String { return value }
        return blocks.filter { $0["type"] as? String == "text" }
          .compactMap { $0["text"] as? String }.joined(separator: "\n")
      }
      switch role {
      case "user":
        try append(ChatEntry(id: id, kind: .user, title: "你", text: text(), timestamp: timestamp))
      case "assistant":
        if blocks.isEmpty, !text().isEmpty {
          try append(
            ChatEntry(id: id, kind: .assistant, title: "Pi", text: text(), timestamp: timestamp))
        }
        for (slot, block) in blocks.enumerated() {
          let type = block["type"] as? String
          if type == "text" || type == "thinking" {
            try append(
              ChatEntry(
                id: "\(id):\(slot)", kind: type == "text" ? .assistant : .thinking,
                title: type == "text" ? "Pi" : "思考过程",
                text: block[type == "text" ? "text" : "thinking"] as? String ?? "",
                timestamp: timestamp))
          } else if type == "toolCall" {
            let input = block["arguments"].flatMap {
              try? JSONSerialization.data(
                withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed])
            }
            try append(
              ChatEntry(
                id: "\(id):\(slot)", kind: .tool,
                title: block["name"] as? String ?? "工具", text: "",
                toolInput: input.map { String(decoding: $0, as: UTF8.self) }, timestamp: timestamp))
          }
        }
        if message["stopReason"] as? String == "error" {
          try append(
            ChatEntry(
              id: "\(id):error", kind: .system, title: "错误",
              text: message["errorMessage"] as? String ?? "模型调用失败", isError: true,
              timestamp: timestamp))
        }
      case "toolResult", "bashExecution":
        try append(
          ChatEntry(
            id: id, kind: .tool,
            title: message["toolName"] as? String ?? "工具",
            text: message["output"] as? String ?? text(),
            isError: message["isError"] as? Bool ?? false,
            toolInput: message["command"] as? String, timestamp: timestamp))
      default: break
      }
    }
    return entries
  }

  private static func date(_ value: Any?) -> Date? {
    if let number = value as? NSNumber {
      return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }
    guard let text = value as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }
}

import Foundation

struct SessionSearchResult: Identifiable, Sendable {
  let session: SessionItem
  let snippet: String?

  var id: String { session.path }
}

// Cache only searchable text, not the full transcript (tool outputs can be very large).
// NSCache is thread-safe: searches run in detached tasks and the OS can reclaim this index.
private final class CachedSessionText: NSObject {
  let messages: [String]

  init(messages: [String]) {
    self.messages = messages
  }
}

enum SessionSearch {
  private static let indexLock = NSLock()
  private static let index: NSCache<NSString, CachedSessionText> = {
    let cache = NSCache<NSString, CachedSessionText>()
    cache.totalCostLimit = 48 * 1_024 * 1_024
    return cache
  }()

  nonisolated private static func messages(in session: SessionItem) -> [String] {
    let url = URL(fileURLWithPath: session.path)
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: session.path),
      let modified = attributes[.modificationDate] as? Date,
      let size = attributes[.size] as? NSNumber
    else { return [] }
    // The catalog date can lag behind a running session. Stat the file so appended messages
    // invalidate the cache even before session discovery refreshes the sidebar.
    let key = "\(session.path)|\(modified.timeIntervalSince1970)|\(size.int64Value)" as NSString
    if let cached = index.object(forKey: key) { return cached.messages }
    // Coalesce overlapping searches (typing a new character cancels the old task).
    indexLock.lock()
    defer { indexLock.unlock() }
    if let cached = index.object(forKey: key) { return cached.messages }
    if Task<Never, Never>.isCancelled { return [] }
    let messages = readSearchableMessages(at: url)
    // Finish indexing the current file even if the user types another character. The next
    // search can immediately reuse it instead of restarting this expensive parse.
    let cost = messages.reduce(0) { $0 + $1.utf16.count * 2 }
    index.setObject(CachedSessionText(messages: messages), forKey: key, cost: cost)
    return messages
  }
  nonisolated static func results(for query: String, in sessions: [SessionItem])
    -> [SessionSearchResult]
  {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return [] }
    var results: [SessionSearchResult] = []
    for session in sessions {
      if Task<Never, Never>.isCancelled { break }
      let titleMatches = session.title.localizedStandardContains(term)
      // Search the same visible branch and message text as the conversation view, not raw
      // JSONL (which also contains tool output, discarded branches and metadata).
      // A matching title needs no disk I/O. For content matches, parse each unchanged
      // session only once rather than reopening every JSONL file on every keystroke.
      if titleMatches {
        results.append(SessionSearchResult(session: session, snippet: nil))
        continue
      }
      if let match = messages(in: session).first(where: { $0.localizedStandardContains(term) }) {
        results.append(
          SessionSearchResult(session: session, snippet: snippet(match, matching: term)))
      }
    }
    return results
  }

  // Unlike transcript rendering, indexing must not restore images or build tool/Markdown
  // entries. Decode each JSONL record once and retain only visible-branch user/assistant text.
  nonisolated private static func readSearchableMessages(at url: URL) -> [String] {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    var parents: [String: String] = [:]
    var messages: [(id: String?, text: String)] = []
    var leafID: String?
    for line in text.split(separator: "\n") {
      guard let data = line.data(using: .utf8),
        let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      if let id = record["id"] as? String {
        leafID = id
        if let parent = record["parentId"] as? String { parents[id] = parent }
      } else {
        leafID = nil
      }
      guard record["type"] as? String == "message",
        let message = record["message"] as? [String: Any],
        let role = message["role"] as? String,
        role == "user" || role == "assistant"
      else { continue }
      let content = message["content"]
      let messageText: String
      if let plain = content as? String {
        messageText = plain
      } else if let blocks = content as? [[String: Any]] {
        messageText = blocks.compactMap { block -> String? in
          guard block["type"] as? String == "text" else { return nil }
          return block["text"] as? String
        }.joined(separator: "\n")
      } else {
        messageText = ""
      }
      if !messageText.isEmpty {
        messages.append((record["id"] as? String, messageText))
      }
    }
    guard let leafID else { return messages.map(\.text) }
    var branch = Set<String>()
    var current: String? = leafID
    while let id = current, branch.insert(id).inserted {
      current = parents[id]
    }
    return messages.compactMap { message in
      guard let id = message.id, branch.contains(id) else { return nil }
      return message.text
    }
  }

  nonisolated private static func snippet(_ text: String, matching term: String) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    guard let range = flat.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
    else {
      return String(flat.prefix(100))
    }
    let start =
      flat.index(range.lowerBound, offsetBy: -32, limitedBy: flat.startIndex) ?? flat.startIndex
    let end = flat.index(range.upperBound, offsetBy: 68, limitedBy: flat.endIndex) ?? flat.endIndex
    return (start == flat.startIndex ? "" : "…") + String(flat[start..<end])
      + (end == flat.endIndex ? "" : "…")
  }
}

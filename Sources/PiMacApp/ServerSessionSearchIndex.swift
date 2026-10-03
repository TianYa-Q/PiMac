import Foundation

private final class ServerSearchText: NSObject {
  let messages: [String]
  init(_ messages: [String]) { self.messages = messages }
}

/// Index server-owned threads without restoring transcript images or tool details.
/// Failed/cancelled reads are never cached as empty content.
@MainActor
final class ServerSessionSearchIndex {
  private let cache: NSCache<NSString, ServerSearchText> = {
    let cache = NSCache<NSString, ServerSearchText>()
    cache.totalCostLimit = 48 * 1_024 * 1_024
    return cache
  }()
  private var generation = UUID()

  func reset() {
    generation = UUID()
    cache.removeAllObjects()
  }

  func messages(
    for query: String, in sessions: [SessionItem],
    load: (String) async throws -> [String]
  ) async throws -> [String: [String]] {
    let query = SessionSearchQuery(query)
    guard !query.isEmpty else { return [:] }
    let current = generation
    var result: [String: [String]] = [:]
    for session in sessions {
      try Task.checkCancellation()
      guard session.path.hasPrefix("t3:") else { continue }
      if query.excluded.isEmpty && query.matches([session.title]) { continue }
      let key = "\(session.path)|\(session.modifiedAt.timeIntervalSince1970)" as NSString
      if let cached = cache.object(forKey: key) {
        result[session.path] = cached.messages
        continue
      }
      // Fetch serially: one keystroke must not fan out hundreds of requests to Server.
      let messages = try await load(String(session.path.dropFirst(3)))
      try Task.checkCancellation()
      guard current == generation else { throw CancellationError() }
      cache.setObject(
        ServerSearchText(messages), forKey: key,
        cost: messages.reduce(0) { $0 + $1.utf16.count * 2 })
      result[session.path] = messages
    }
    return result
  }
}

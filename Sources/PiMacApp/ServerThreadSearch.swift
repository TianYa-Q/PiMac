import Foundation

struct ServerThreadSearchQuery {
  let text: String

  init(_ text: String) {
    self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 与上游 searchThreads 的长度约束一致；查询内容不解释、不改写。
  var validationMessage: String? {
    if text.isEmpty { return nil }
    if text.utf16.count < 2 { return "请输入至少 2 个字符" }
    if text.utf16.count > 200 { return "搜索内容不能超过 200 个字符" }
    return nil
  }

  var canSearch: Bool { !text.isEmpty && validationMessage == nil }
}

struct ServerThreadSearchResponse: Decodable, Sendable {
  struct Match: Decodable, Sendable {
    let threadId: String
    let projectId: String
    let source: String
    let snippet: String
    let messageCreatedAt: String?
  }
  let matches: [Match]

  func results(in sessions: [SessionItem]) -> [SessionSearchResult] {
    let byPath = Dictionary(sessions.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    // 只按当前侧栏范围过滤；排序和摘要完全沿用 Server，不补充本地标题命中。
    return matches.compactMap { match in
      guard let session = byPath["t3:\(match.threadId)"] else { return nil }
      return SessionSearchResult(session: session, snippet: match.snippet)
    }
  }
}

import Foundation

/// 所有原生入口共享固定资源中的官方 Schema、剪贴板和链接函数。
enum T3ThreadContext {
  private static let runtime = T3StreamReducer(kind: .thread)

  static func copy(environmentID: String, threadID: String, title: String) async throws
    -> T3ContextClipboard
  {
    let result = try await runtime.prepare(
      .prepareThreadCopy,
      input: ImmutableJSONSnapshot(value: [
        "environmentId": environmentID, "threadId": threadID, "title": title,
      ])
    ).value
    guard let text = result["text"] as? String, let fragment = result["fragment"] as? String,
      let html = result["html"] as? String
    else { throw T3StreamReducer.Failure.invalidFrame }
    return T3ContextClipboard(text: text, fragment: fragment, html: html)
  }

  static func paste(
    _ clipboard: T3ContextClipboard, existing: T3MessageContext?, environmentID: String
  ) async throws -> T3ThreadPaste {
    var input: [String: Any] = [
      "text": clipboard.text, "fragment": clipboard.fragment, "html": clipboard.html,
      "environmentId": environmentID, "identity": UUID().uuidString,
    ]
    if let existing { input["existing"] = try existing.object() }
    let result = try await runtime.prepare(
      .prepareThreadPaste, input: ImmutableJSONSnapshot(value: input)
    ).value
    guard let text = result["text"] as? String, let context = result["context"] as? [String: Any]
    else { throw T3StreamReducer.Failure.invalidFrame }
    return try T3ThreadPaste(text: text, context: T3MessageContext(context))
  }

  static func dispatchContext(
    text: String, context: T3MessageContext?, environmentID: String
  ) async throws -> [String: Any] {
    var input: [String: Any] = ["text": text, "environmentId": environmentID]
    if let context { input["context"] = try context.object() }
    return try await runtime.prepare(
      .prepareContextDispatch, input: ImmutableJSONSnapshot(value: input)
    ).value
  }
}

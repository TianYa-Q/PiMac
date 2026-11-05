import AppKit
import SwiftUI

/// 原始官方 records 整体保存，不因原生 UI 尚不认识某种记录而剥离它的 payload。
/// 外部剪贴板和发送边界的完整校验交给同版本官方 Schema。
struct T3MessageContext: Codable, Equatable, Sendable {
  private let data: Data
  private enum CodingKeys: CodingKey { case data }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    data = try container.decode(Data.self, forKey: .data)
    _ = try object()
  }

  init(_ object: [String: Any]) throws {
    guard object["version"] as? Int == 1, object["records"] is [[String: Any]] else {
      throw CocoaError(.coderReadCorrupt)
    }
    data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  func object() throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["version"] as? Int == 1, object["records"] is [[String: Any]]
    else { throw CocoaError(.coderReadCorrupt) }
    return object
  }

  struct ThreadReference: Identifiable, Decodable, Equatable, Sendable {
    let contextId: String
    let label: String
    let environmentId: String
    let threadId: String
    let title: String
    var id: String { contextId }
    var href: String { "t3-context://v1/thread/\(contextId)" }
  }

  func threads(in text: String) throws -> [ThreadReference] {
    let records = try object()["records"] as? [[String: Any]] ?? []
    return try records.filter { $0["kind"] as? String == "thread" }.map {
      try JSONDecoder().decode(
        ThreadReference.self, from: JSONSerialization.data(withJSONObject: $0))
    }.filter { text.contains("](\($0.href))") }
  }

  static func merging(_ contexts: [Self]) throws -> Self? {
    guard !contexts.isEmpty else { return nil }
    var records: [[String: Any]] = []
    var seen: [String: NSDictionary] = [:]
    for context in contexts {
      for record in try context.object()["records"] as? [[String: Any]] ?? [] {
        guard let id = record["contextId"] as? String else { throw CocoaError(.coderReadCorrupt) }
        if let previous = seen[id] {
          guard previous.isEqual(to: record) else { throw CocoaError(.validationMultipleErrors) }
        } else {
          seen[id] = NSDictionary(dictionary: record)
          records.append(record)
        }
      }
    }
    return try Self(["version": 1, "records": records])
  }

  static func read(_ value: Any?) -> Self? {
    guard let value = value as? [String: Any] else { return nil }
    // 已经过官方订阅/HTTP Schema 校验；损坏的记录仍在原始投影中，不伪造有效引用。
    return try? Self(value)
  }
}

struct T3ContextClipboard: Sendable {
  static let nativeType = NSPasteboard.PasteboardType("app.t3.context-fragment")
  static let webType = NSPasteboard.PasteboardType("web application/x-t3-context-fragment+json")
  static let mimeType = NSPasteboard.PasteboardType("application/x-t3-context-fragment+json")
  let text: String
  let fragment: String
  let html: String

  @MainActor
  init?(pasteboard: NSPasteboard) {
    let types = Set(pasteboard.types ?? [])
    let fragment =
      [Self.nativeType, Self.webType, Self.mimeType].filter(types.contains).compactMap {
        pasteboard.string(forType: $0)
          ?? pasteboard.data(forType: $0).flatMap { String(data: $0, encoding: .utf8) }
      }.first ?? ""
    let html =
      pasteboard.string(forType: .html)
      ?? pasteboard.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    guard !fragment.isEmpty || html.contains("data-t3-context-fragment=") else { return nil }
    self.text = pasteboard.string(forType: .string) ?? ""
    self.fragment = fragment
    self.html = html
  }

  init(text: String, fragment: String, html: String) {
    self.text = text
    self.fragment = fragment
    self.html = html
  }

  @MainActor
  func write(to pasteboard: NSPasteboard) throws {
    // Web 的带空格 MIME 不是合法 macOS UTI；原生写官方 iOS UTI，Web 通过 HTML fallback 读取。
    let item = NSPasteboardItem()
    guard item.setString(text, forType: .string),
      item.setString(fragment, forType: Self.nativeType),
      item.setString(html, forType: .html)
    else { throw CocoaError(.fileWriteUnknown) }
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
  }
}

struct T3ThreadPaste: Sendable {
  let text: String
  let context: T3MessageContext
}

private struct ThreadContextActionKey: EnvironmentKey {
  static let defaultValue: ((T3MessageContext.ThreadReference) -> Void)? = nil
}

extension EnvironmentValues {
  var openThreadContext: ((T3MessageContext.ThreadReference) -> Void)? {
    get { self[ThreadContextActionKey.self] }
    set { self[ThreadContextActionKey.self] = newValue }
  }
}

/// 引用入口保持安静：只显示实际仍在正文中的会话，并复用现有会话导航。
struct ThreadContextChips: View {
  let text: String
  let context: T3MessageContext?
  @Environment(\.openThreadContext) private var openThread

  var body: some View {
    if let context, let threads = try? context.threads(in: text), !threads.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(threads) { thread in
            Button {
              openThread?(thread)
            } label: {
              Label(thread.label, systemImage: "bubble.left.and.bubble.right")
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("打开引用会话：\(thread.title)")
          }
        }
      }
      .frame(height: 28)
    }
  }
}

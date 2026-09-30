import Foundation

/// Pi persists bounded metadata, not nested tool output. Keep the same representation
/// in live views and restored history rather than fabricating standalone transcript rows.
struct NestedToolCall: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  var input: String?
  var status: String
  var durationMs: Double?
  var error: String?

  static func from(_ value: Any?) -> [Self] {
    guard let raw = value as? PiRPCClient.JSON,
      let calls = raw["calls"] as? [PiRPCClient.JSON]
    else { return [] }
    return calls.prefix(256).compactMap { call in
      guard let id = call["id"] as? String, let name = call["name"] as? String else { return nil }
      let args = call["arguments"]
      let input =
        args.flatMap { AppModel.toolInputText(toolName: name, args: $0) }
        ?? (call["argumentsBytes"] as? NSNumber).map { "参数已省略（\($0.intValue) bytes）" }
      return Self(
        id: id, name: name, input: input, status: call["status"] as? String ?? "unfinished",
        durationMs: (call["durationMs"] as? NSNumber)?.doubleValue,
        error: call["error"] as? String)
    }
  }
}

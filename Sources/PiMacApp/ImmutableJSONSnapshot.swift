import Foundation

/// JSONSerialization 默认生成不可变容器；只共享只读树，不使用 mutableContainers。
/// Dictionary 的值语义让调用方后续的表现层修改创建副本，不与后台解析/摘要任务共享写入。
struct ImmutableJSONSnapshot: @unchecked Sendable {
  let value: [String: Any]

  static func decode(_ data: Data) async throws -> Self {
    try await Task.detached(priority: .userInitiated) {
      guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CocoaError(.coderInvalidValue)
      }
      return Self(value: value)
    }.value
  }

  static func frames(_ data: Data) async throws -> [Self] {
    try await Task.detached(priority: .userInitiated) {
      let value = try JSONSerialization.jsonObject(with: data)
      if let frame = value as? [String: Any] { return [Self(value: frame)] }
      if let frames = value as? [[String: Any]] { return frames.map { Self(value: $0) } }
      throw CocoaError(.coderInvalidValue)
    }.value
  }

  func encode() async throws -> Data {
    try await Task.detached(priority: .userInitiated) {
      try JSONSerialization.data(withJSONObject: value)
    }.value
  }

  func fingerprint() async throws -> Data {
    try await Task.detached(priority: .utility) {
      try T3DesktopClient.snapshotFingerprint(value)
    }.value
  }
}

import Foundation
import Testing

@testable import PiMacApp

struct SessionDiscoveryTests {
  @Test
  func discoversCompleteUserRecordsBeyondPreviewLimit() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("session-discovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.standardizedFileURL.path
    func record(_ value: [String: Any]) throws -> Data {
      var data = try JSONSerialization.data(withJSONObject: value)
      data.append(0x0A)
      return data
    }
    let header = try record(["type": "session", "cwd": project])
    let user = try record([
      "type": "message", "timestamp": "2026-01-02T10:00:00Z",
      "message": ["role": "user", "content": [
        ["type": "text", "text": "刚刚的会话"],
        ["type": "image", "data": String(repeating: "a", count: 600_000)],
      ]],
    ])
    try (header + user).write(to: root.appendingPathComponent("image.jsonl"))
    let config = try record([
      "type": "custom", "data": String(repeating: "中", count: 100_000),
    ])
    // Also cover a user record after a large configuration entry, without a final newline.
    try (header + config + user.dropLast()).write(to: root.appendingPathComponent("late.jsonl"))
    try header.write(to: root.appendingPathComponent("draft.jsonl"))
    try (try record(["type": "session", "cwd": "/another-project"]) + user)
      .write(to: root.appendingPathComponent("other.jsonl"))

    let sessions = AppModel.discoverSessions(for: project, root: root)
    #expect(sessions.count == 2)
    #expect(Set(sessions.map(\.title)) == ["刚刚的会话"])
    let expected = try #require(ISO8601DateFormatter().date(from: "2026-01-02T10:00:00Z"))
    #expect(sessions.allSatisfy { $0.modifiedAt == expected })
  }
}

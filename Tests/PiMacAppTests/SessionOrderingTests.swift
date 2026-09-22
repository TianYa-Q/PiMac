import Foundation
import Testing

@testable import PiMacApp

struct SessionOrderingTests {
  @Test
  func sessionActivityUsesLatestUserMessageInsteadOfLaterAssistantOutput() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("session-ordering-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    func record(role: String, timestamp: String, text: String) throws -> Data {
      let value: [String: Any] = [
        "type": "message",
        "timestamp": timestamp,
        "message": ["role": role, "content": text],
      ]
      var data = try JSONSerialization.data(withJSONObject: value)
      data.append(0x0A)
      return data
    }

    var contents = Data()
    contents.append(try record(role: "user", timestamp: "2026-01-01T10:00:00Z", text: "first"))
    contents.append(try record(role: "user", timestamp: "2026-01-02T10:00:00Z", text: "latest"))
    // Keep the latest user message outside the final 1 MiB to cover reverse chunk scanning.
    contents.append(
      try record(
        role: "assistant", timestamp: "2026-01-03T10:00:00Z",
        text: String(repeating: "x", count: 1_100_000)))
    try contents.write(to: fileURL)

    let expected = try #require(ISO8601DateFormatter().date(from: "2026-01-02T10:00:00Z"))
    #expect(AppModel.latestUserMessageDate(inFile: fileURL) == expected)
  }
}

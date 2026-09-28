import Foundation
import Testing

@testable import PiMacApp

struct MessageTimestampTests {
  @Test
  func newEntriesCaptureCreationTime() throws {
    let before = Date.now
    let entry = ChatEntry(id: "new", kind: .user, title: "你", text: "你好")
    let timestamp = try #require(entry.timestamp)
    #expect(timestamp >= before && timestamp <= Date.now)
  }

  @Test
  func rpcMessagesPreserveMillisecondsAcrossAllCards() {
    let milliseconds = 1_750_000_000_123.0
    let messages: [PiRPCClient.JSON] = [
      ["role": "user", "content": "问题", "timestamp": milliseconds],
      [
        "role": "assistant", "timestamp": milliseconds,
        "content": [
          ["type": "thinking", "thinking": "分析"],
          ["type": "text", "text": "回答"],
        ], "stopReason": "error", "errorMessage": "失败",
      ],
      ["role": "toolResult", "toolName": "read", "content": "结果", "timestamp": milliseconds],
      ["role": "bashExecution", "output": "结果", "timestamp": milliseconds],
    ]
    let entries = AppModel.chatEntries(from: messages)
    #expect(entries.count == 6)
    #expect(
      entries.allSatisfy { $0.timestamp == Date(timeIntervalSince1970: milliseconds / 1_000) })
  }

  @Test
  func missingHistoricalTimestampDoesNotUseCurrentTime() throws {
    let entry = try #require(AppModel.chatEntry(from: ["role": "user", "content": "旧消息"]))
    #expect(entry.timestamp == nil)
  }

  @Test
  func sessionRecordsRestoreFallbackAndCompactionDates() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let iso = "2025-06-15T10:20:30.123Z"
    let records: [PiRPCClient.JSON] = [
      [
        "type": "message", "id": "user", "timestamp": iso,
        "message": ["role": "user", "content": "问题"],
      ],
      [
        "type": "compaction", "id": "compact", "parentId": "user", "timestamp": iso,
        "summary": "摘要",
      ],
      [
        "type": "message", "id": "answer", "parentId": "compact", "timestamp": iso,
        "message": ["role": "assistant", "content": "回答", "timestamp": 1_000],
      ],
    ]
    let data = try records.reduce(into: Data()) { result, record in
      result.append(try JSONSerialization.data(withJSONObject: record))
      result.append(Data("\n".utf8))
    }
    try data.write(to: url)
    let entries = AppModel.loadTranscript(at: url.path)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    #expect(entries.count == 3)
    #expect(entries[0].timestamp == formatter.date(from: iso))
    #expect(entries[1].timestamp == formatter.date(from: iso))
    #expect(entries[2].timestamp == Date(timeIntervalSince1970: 1))
  }
}

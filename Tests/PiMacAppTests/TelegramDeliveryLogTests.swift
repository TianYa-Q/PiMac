import Foundation
import Testing

@testable import PiMacApp

struct TelegramDeliveryLogTests {
  @Test @MainActor
  func appendsCorrelatedEventsAndRotates() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("delivery.log")
    let id = UUID()
    let session = "/sessions/session-123.jsonl"
    TelegramDeliveryLog.record(
      "submitted", task: id, sessionPath: session,
      details: "model=openai-codex/gpt-6-sol", destination: file)
    TelegramDeliveryLog.record(
      "agent_settled", task: id, sessionPath: session,
      destination: file)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(
      text.contains(
        "task=\(id.uuidString) session=session-123 submitted model=openai-codex/gpt-6-sol"))
    #expect(text.contains("task=\(id.uuidString) session=session-123 agent_settled"))
    try Data(repeating: 65, count: 1_000_001).write(to: file)
    TelegramDeliveryLog.record(
      "send_started", task: id, sessionPath: session,
      destination: file)
    #expect(try Data(contentsOf: file.appendingPathExtension("old")).count == 1_000_001)
    #expect(try String(contentsOf: file, encoding: .utf8).contains("send_started"))
  }
}

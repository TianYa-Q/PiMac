import Foundation
import Testing

@testable import PiMacApp

struct T3SessionFileReaderTests {
  private func data(_ records: [[String: Any]]) throws -> Data {
    var data = Data()
    for record in records {
      data.append(try JSONSerialization.data(withJSONObject: record))
      data.append(0x0A)
    }
    return data
  }

  @Test func savedHistoryUsesVisibleBranchStableIDsAndNoAttachments() throws {
    let input = try data([
      ["type": "session", "cwd": "/project", "id": "session"],
      [
        "type": "message", "id": "user", "parentId": NSNull(), "timestamp": "2026-10-02T10:00:00Z",
        "message": [
          "role": "user",
          "content": [
            ["type": "text", "text": "before\u{2028}after\u{2029}"],
            ["type": "image", "data": "must-not-restore", "mimeType": "image/png"],
          ],
        ],
      ],
      [
        "type": "message", "id": "abandoned", "parentId": "user",
        "message": ["role": "assistant", "content": "abandoned branch"],
      ],
      [
        "type": "message", "id": "answer", "parentId": "user",
        "message": [
          "role": "assistant",
          "content": [
            ["type": "thinking", "thinking": "reasoning"],
            ["type": "text", "text": "visible answer"],
            ["type": "toolCall", "name": "read", "arguments": ["path": "README.md"]],
          ],
        ],
      ],
      [
        "type": "message", "id": "tool", "parentId": "answer",
        "message": [
          "role": "toolResult", "toolName": "read", "content": "inline output",
          "details": ["fullOutputPath": "/must/not/read"],
        ],
      ],
    ])
    let a = try T3SessionFileReader.parse(input, project: "/project")
    let b = try T3SessionFileReader.parse(input, project: "/project")
    #expect(a == b)
    #expect(a.map(\.id) == ["user", "answer:0", "answer:1", "answer:2", "tool"])
    #expect(a.first?.text == "before\u{2028}after\u{2029}")
    #expect(a.last?.text == "inline output")
    #expect(a.allSatisfy { $0.attachments.isEmpty && !$0.isRunning })
    #expect(a.first?.timestamp == Date(timeIntervalSince1970: 1_790_935_200))
  }

  @Test func wrongProjectAndDuplicateRecordIDsAreRejected() throws {
    let header: [String: Any] = ["type": "session", "cwd": "/project"]
    #expect(throws: T3WorkspaceReadModel.ReadError.self) {
      _ = try T3SessionFileReader.parse(data([header]), project: "/other")
    }
    let message: [String: Any] = [
      "type": "message", "id": "duplicate",
      "message": ["role": "user", "content": "hello"],
    ]
    #expect(throws: T3WorkspaceReadModel.ReadError.self) {
      _ = try T3SessionFileReader.parse(data([header, message, message]), project: "/project")
    }
  }

  @Test func legacyHistoryAndAnUnfinishedAppendRemainReadable() throws {
    var input = try data([
      ["type": "session", "cwd": "/project"],
      ["type": "message", "message": ["role": "user", "content": "legacy"]],
      ["type": "message", "message": ["role": "assistant", "content": "reply"]],
    ])
    input.append(Data("{\"type\":\"message\",\"unfinished\":".utf8))
    let result = try T3SessionFileReader.parse(input, project: "/project")
    #expect(result.map(\.text) == ["legacy", "reply"])
    #expect(result.map(\.id) == ["record-1", "record-2"])
  }

  @Test func cachedHistoryRefreshesOnAppendAndRefusesSymlinks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("session.jsonl")
    var input = try data([
      ["type": "session", "cwd": "/project"],
      ["type": "message", "id": "u", "message": ["role": "user", "content": "hello"]],
    ])
    try input.write(to: file)
    let a = try T3SessionFileReader.read(path: file.path, project: "/project")
    #expect(try T3SessionFileReader.read(path: file.path, project: "/project") == a)
    input.append(
      try data([
        [
          "type": "message", "id": "a", "parentId": "u",
          "message": ["role": "assistant", "content": "new reply"],
        ]
      ]))
    try input.write(to: file)
    #expect(try T3SessionFileReader.read(path: file.path, project: "/project").count == 2)
    #expect(throws: T3WorkspaceReadModel.ReadError.self) {
      _ = try T3SessionFileReader.read(path: file.path, project: "/other")
    }
    let link = directory.appendingPathComponent("link.jsonl")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(throws: T3WorkspaceReadModel.ReadError.self) {
      _ = try T3SessionFileReader.read(path: link.path, project: "/project")
    }
  }
}

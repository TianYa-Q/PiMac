import Foundation
import Testing

@testable import PiMacApp

struct TranscriptHistoryTests {
  private let rpcMessages: [PiRPCClient.JSON] = [
    ["role": "user", "content": "压缩后的问题"]
  ]

  private var complete: [ChatEntry] {
    [
      ChatEntry(id: "before", kind: .user, title: "You", text: "压缩前的问题"),
      ChatEntry(id: "compact", kind: .compaction, title: "上下文压缩", text: "摘要"),
      ChatEntry(id: "after", kind: .user, title: "You", text: "压缩后的问题"),
    ]
  }

  @Test @MainActor
  func lateRPCSnapshotDoesNotTruncateCompleteHistory() {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.currentSessionPath = "/session.jsonl"
    model.applyCompleteTranscript(complete, at: model.currentSessionPath, cacheKey: "v1")
    model.applyRPCMessageSnapshot(rpcMessages)
    #expect(model.messages.map(\.id) == ["before", "compact", "after"])
    // A subsequent full-file refresh can still replace the history.
    model.applyCompleteTranscript(complete, at: model.currentSessionPath, cacheKey: "v2")
    model.applyRPCMessageSnapshot(rpcMessages)
    #expect(model.messages.count == 3)
  }

  @Test @MainActor
  func completeHistoryReplacesAnEarlierRPCSnapshot() {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.currentSessionPath = "/session.jsonl"
    model.applyRPCMessageSnapshot(rpcMessages)
    #expect(model.messages.count == 1)
    model.applyCompleteTranscript(complete, at: model.currentSessionPath, cacheKey: "v1")
    #expect(model.messages.map(\.id) == ["before", "compact", "after"])
  }

  @Test @MainActor
  func previousSessionDoesNotSuppressFallbackForAnotherSession() {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.currentSessionPath = "/a.jsonl"
    model.applyCompleteTranscript(complete, at: model.currentSessionPath, cacheKey: "a")
    model.currentSessionPath = "/b.jsonl"
    model.applyRPCMessageSnapshot(rpcMessages)
    #expect(model.messages.map(\.text) == ["压缩后的问题"])
    model.applyCompleteTranscript(complete, at: "/a.jsonl", cacheKey: "a")
    #expect(model.messages.count == 1)
  }

  @Test
  func jsonlConnectsHistoryAcrossCompactionOnTheActiveBranch() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let records: [PiRPCClient.JSON] = [
      ["type": "session", "id": "session"],
      [
        "type": "message", "id": "before", "parentId": NSNull(),
        "message": ["role": "user", "content": "压缩前的问题"],
      ],
      [
        "type": "message", "id": "abandoned", "parentId": "before",
        "message": ["role": "user", "content": "废弃分支"],
      ],
      [
        "type": "compaction", "id": "compact", "parentId": "before",
        "firstKeptEntryId": "before", "summary": "摘要",
      ],
      [
        "type": "message", "id": "after", "parentId": "compact",
        "message": ["role": "user", "content": "压缩后的问题"],
      ],
    ]
    let text = try records.map {
      String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
    }.joined(separator: "\n")
    try text.write(to: url, atomically: true, encoding: .utf8)
    let entries = AppModel.loadTranscript(at: url.path)
    #expect(entries.map(\.text) == ["压缩前的问题", "摘要", "压缩后的问题"])
    #expect(entries[1].kind == .compaction)
  }
}

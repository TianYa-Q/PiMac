import Foundation
import Testing

@testable import PiMacApp

struct UsageDashboardTests {
  @Test func scannerAggregatesTokensCostModelsAndProjects() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let nested = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = """
      {"type":"session","cwd":"/tmp/alpha","timestamp":"2025-01-01T00:00:00.000Z"}
      {"type":"message","timestamp":"2025-01-02T10:00:00.000Z","message":{"role":"assistant","model":"model-a","usage":{"input":100,"output":20,"cacheRead":50,"cacheWrite":5,"totalTokens":175,"cost":{"total":0.25}}}}
      {"type":"message","timestamp":"2025-01-02T10:01:00.000Z","message":{"role":"user","content":"ignored"}}
      """
    let second = """
      {"type":"session","cwd":"/tmp/alpha","timestamp":"2025-01-03T00:00:00.000Z"}
      {"type":"message","timestamp":"2025-01-03T10:00:00.000Z","message":{"role":"assistant","model":"model-b","usage":{"input":40,"output":10,"cacheRead":0,"cacheWrite":0,"totalTokens":50,"cost":{"total":0.1}}}}
      """
    try first.write(
      to: nested.appendingPathComponent("one.jsonl"), atomically: true, encoding: .utf8)
    try second.write(
      to: nested.appendingPathComponent("two.jsonl"), atomically: true, encoding: .utf8)

    let result = UsageScanner.scan(root: root, startingAt: nil)

    #expect(result.totalTokens == 225)
    #expect(result.inputTokens == 140)
    #expect(result.outputTokens == 30)
    #expect(result.cacheReadTokens == 50)
    #expect(result.cacheWriteTokens == 5)
    #expect(abs(result.cost - 0.35) < 0.000_001)
    #expect(result.requests == 2)
    #expect(result.sessions == 2)
    #expect(result.days.count == 2)
    #expect(result.models.map(\.name) == ["model-a", "model-b"])
    #expect(result.projects.first?.sessions == 2)
    #expect(result.projects.first?.tokens == 225)
  }

  @Test func indexReusesUnchangedFilesAndUpdatesChangedOrRemovedSessions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = root.appendingPathComponent("cache/index.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.jsonl")
    let header = "{\"type\":\"session\",\"cwd\":\"/tmp/example\"}\n"
    let message =
      "{\"type\":\"message\",\"timestamp\":\"2025-02-01T10:00:00Z\",\"message\":{\"role\":\"assistant\",\"model\":\"test\",\"usage\":{\"totalTokens\":100}}}\n"
    try (header + message).write(to: file, atomically: true, encoding: .utf8)
    let first = UsageScanner.scan(root: root, startingAt: nil, cacheURL: cache)
    #expect(first.totalTokens == 100)
    #expect(FileManager.default.fileExists(atPath: cache.path))
    let cacheDate = try cache.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    let second = UsageScanner.scan(root: root, startingAt: nil, cacheURL: cache)
    #expect(second.totalTokens == 100)
    #expect(
      try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        == cacheDate)

    try (header + message + message).write(to: file, atomically: true, encoding: .utf8)
    #expect(UsageScanner.scan(root: root, startingAt: nil, cacheURL: cache).totalTokens == 200)
    let start = ISO8601DateFormatter().date(from: "2025-02-02T00:00:00Z")!
    #expect(UsageScanner.scan(root: root, startingAt: start, cacheURL: cache).requests == 0)
    try FileManager.default.removeItem(at: file)
    #expect(UsageScanner.scan(root: root, startingAt: nil, cacheURL: cache).requests == 0)
  }

  @Test func scannerIncludesNestedToolSummaryAndIndependentUsageOnce() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let rows: [[String: Any]] = [
      [
        "type": "message",
        "message": [
          "role": "assistant", "model": "chat",
          "usage": ["totalTokens": 10, "cost": ["total": 0.1]],
        ],
      ],
      [
        "type": "message",
        "message": [
          "role": "toolResult", "toolName": "codemode",
          "usage": ["totalTokens": 20, "cost": ["total": 0.2]],
          "details": ["usage": ["totalTokens": 20]],
        ],
      ],
      [
        "type": "compaction", "usage": ["totalTokens": 30, "cost": ["total": 0.3]],
        "details": ["compactionModelId": "summary"],
      ],
      ["type": "branch_summary", "usage": ["totalTokens": 40, "cost": ["total": 0.4]]],
      [
        "type": "usage", "kind": "future-kind", "model": "warm",
        "usage": ["input": 10, "cacheRead": 40, "cost": ["total": 0.5]],
      ],
      ["type": "context_edit", "targetId": "old", "replacement": NSNull()],
    ]
    var data = Data("{\"type\":\"session\",\"cwd\":\"/tmp/test\"}\n".utf8)
    for var row in rows {
      row["timestamp"] = "2025-02-01T10:00:00Z"
      data.append(try JSONSerialization.data(withJSONObject: row))
      data.append(0x0A)
    }
    try data.write(to: root.appendingPathComponent("usage.jsonl"))
    let result = UsageScanner.scan(root: root, startingAt: nil)
    #expect(result.totalTokens == 150)
    #expect(abs(result.cost - 1.5) < 0.000001)
    #expect(result.requests == 5)
    #expect(result.models.contains { $0.name == "工具内部调用 · codemode" && $0.tokens == 20 })
    #expect(result.models.contains { $0.name == "summary" && $0.tokens == 30 })
  }

  @Test func legacyIndexIsRebuiltForUnchangedSessions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("usage.jsonl")
    try
      "{\"type\":\"session\",\"cwd\":\"/tmp/test\"}\n{\"type\":\"usage\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"usage\":{\"totalTokens\":50}}\n"
      .write(to: file, atomically: true, encoding: .utf8)
    let cache = root.appendingPathComponent("cache.json")
    #expect(UsageScanner.scan(root: root, startingAt: nil, cacheURL: cache).totalTokens == 50)
    var legacy = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
    legacy.removeValue(forKey: "version")
    legacy["files"] = [:]
    try JSONSerialization.data(withJSONObject: legacy).write(to: cache)
    #expect(UsageScanner.scan(root: root, startingAt: nil, cacheURL: cache).totalTokens == 50)
    let rebuilt = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
    #expect(rebuilt["version"] as? Int == 3)
  }

  @Test func scannerHonorsStartDate() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let contents = """
      {"type":"session","cwd":"/tmp/project"}
      {"type":"message","timestamp":"2025-01-01T10:00:00.000Z","message":{"role":"assistant","model":"model-a","usage":{"totalTokens":100}}}
      {"type":"message","timestamp":"2025-02-01T10:00:00.000Z","message":{"role":"assistant","model":"model-a","usage":{"totalTokens":200}}}
      """
    try contents.write(
      to: root.appendingPathComponent("usage.jsonl"), atomically: true, encoding: .utf8)

    let start = ISO8601DateFormatter().date(from: "2025-01-15T00:00:00Z")!
    let result = UsageScanner.scan(root: root, startingAt: start)

    #expect(result.totalTokens == 200)
    #expect(result.requests == 1)
    #expect(result.sessions == 1)
  }
}

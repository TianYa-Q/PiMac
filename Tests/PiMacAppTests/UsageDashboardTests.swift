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

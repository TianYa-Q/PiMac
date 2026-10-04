import Foundation
import Testing

@testable import PiMacApp

struct UsageSafetyTests {
  @Test func metricsRejectBooleansNegativeFractionsAndOutOfRangeValues() {
    for value: Any in [true, -1, 1.5, Double.infinity, Double.nan, Double(Int.max), "12"] {
      #expect(UsageArithmetic.integer(value, fallback: 7) == 7)
    }
    #expect(UsageArithmetic.integer(42) == 42)
    #expect(UsageArithmetic.cost(true) == 0)
    #expect(UsageArithmetic.cost(-3) == 0)
    #expect(UsageArithmetic.cost(Double.infinity) == 0)
    #expect(UsageArithmetic.add(Int.max - 1, 5) == Int.max)
    #expect(
      UsageArithmetic.add(Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude).isFinite)
    var snapshot = UsageSnapshot()
    snapshot.inputTokens = Int.max
    snapshot.cacheReadTokens = Int.max
    snapshot.cacheWriteTokens = Int.max
    #expect(abs((snapshot.cacheHitPercent ?? 0) - 100.0 / 3) < 0.001)
  }

  @Test func streamingScannerRecoversAfterOversizedRecordAndHandlesFinalLine() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let header = "{\"type\":\"session\",\"cwd\":\"/tmp/test\"}\n"
    let huge = String(repeating: "x", count: 16 * 1024 * 1024 + 1) + "\n"
    let message =
      "{\"type\":\"usage\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"usage\":{\"totalTokens\":9}}"
    try (header + huge + message).write(
      to: root.appendingPathComponent("usage.jsonl"), atomically: true, encoding: .utf8)
    let result = UsageScanner.scan(root: root, startingAt: nil)
    #expect(result.totalTokens == 9)
    #expect(result.requests == 1)
  }

  @Test func corruptMetricsCannotOverflowScannerAndTiesAreStable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let value = Int.max / 2 + 1
    let header = "{\"type\":\"session\",\"cwd\":\"/tmp/test\"}\n"
    let records = ["z", "a", "z", "a"].map { model in
      "{\"type\":\"usage\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"model\":\"\(model)\",\"usage\":{\"input\":\(value),\"output\":\(value),\"cacheRead\":true,\"cacheWrite\":-3,\"cost\":-1}}"
    }
    try (header + records.joined(separator: "\n")).write(
      to: root.appendingPathComponent("usage.jsonl"), atomically: true, encoding: .utf8)
    let result = UsageScanner.scan(root: root, startingAt: nil)
    #expect(result.totalTokens == Int.max)
    #expect(result.inputTokens == Int.max)
    #expect(result.cacheReadTokens == 0)
    #expect(result.cacheWriteTokens == 0)
    #expect(result.cost == 0)
    #expect(result.models.map(\.name) == ["a", "z"])
  }

  @Test func csvQuotesUnicodeAndNeutralizesSpreadsheetFormulas() {
    var snapshot = UsageSnapshot()
    snapshot.models = [ModelUsage(name: "  =恶意,\"公式\"\n行", tokens: 2, cost: 0.1, requests: 1)]
    snapshot.projects = [ProjectUsage(path: "/tmp/项目", tokens: 2, cost: 0.1, sessions: 1)]
    let csv = UsageCSV.export(snapshot)
    #expect(csv.contains("\"'  =恶意,\"\"公式\"\"\n行\""))
    #expect(csv.contains("\"/tmp/项目\""))
    #expect(csv.hasSuffix("\r\n"))
    #expect(csv.components(separatedBy: "\r\n").count == 5)
  }
}

import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3CompactionMetricsTests {
  private func snapshot(usageDate: String = "2026-10-10T12:16:29.797Z",
                        items: [[String: Any]]? = nil) -> [String: Any] {
    ["projection": [
      "thread": ["id": "thread"],
      "runs": [["id": "run", "status": "running"]],
      "attempts": [["id": "attempt", "runId": "run"]],
      "providerTurns": [
        ["id": "old", "tokenUsage": ["usedTokens": 204203, "maxTokens": 272000,
                                     "updatedAt": usageDate]],
        ["id": "current", "runAttemptId": "attempt", "status": "running",
         "turnTokenUsage": ["inputTokens": 400, "cachedInputTokens": 250],
         "piMetrics": ["totalCostUsd": 0.2, "speedMethod": "aa-approx-v1",
                       "speedTokens": 100, "speedDurationMs": 2000]],
      ],
      "turnItems": items ?? [compaction()],
    ]]
  }

  private func compaction(date: String = "2026-10-10T12:45:03.700Z",
                          after: Int = 31542) -> [String: Any] {
    ["id": "compact", "type": "compaction", "status": "completed",
     "providerTurnId": "current", "beforeTokenCount": 256014,
     "afterTokenCount": after, "completedAt": date]
  }

  @Test func runningTaskUsesCompletedCompactionInsteadOfPreviousTurnContext() throws {
    let native = snapshot()
    let stats = try #require(T3V2Presentation.stats(native))
    #expect(stats.totalTokens == 31542)
    #expect(stats.contextWindow == 272000)
    #expect(abs((stats.contextPercent ?? 0) - 11.5963235294) < 0.00001)
    #expect(stats.contextIsEstimated == true)
    #expect(stats.inputTokens == 150)
    #expect(stats.cacheReadTokens == 250)
    #expect(stats.cost == 0.2)
    #expect(stats.outputTokensPerSecond == 50)
    let metrics = try #require(T3V2Presentation.detail(native)["sessionStats"] as? [String: Any])
    #expect(metrics["totalTokens"] as? Int == 31542)
    #expect(metrics["contextIsEstimated"] as? Bool == true)
  }

  @Test func newerAndEqualUsageReplaceEstimate() throws {
    for date in ["2026-10-10T12:46:00Z", "2026-10-10T12:45:03.700Z"] {
      let stats = try #require(T3V2Presentation.stats(snapshot(usageDate: date)))
      #expect(stats.totalTokens == 204203)
      #expect(stats.contextIsEstimated != true)
    }
  }

  @Test func freshRunningTurnUsageSupersedesCompactionWithoutWaitingForSettlement() {
    var native = snapshot()
    var projection = native["projection"] as! [String: Any]
    var turns = projection["providerTurns"] as! [[String: Any]]
    turns[1]["tokenUsage"] = ["usedTokens": 42000, "maxTokens": 272000,
                             "updatedAt": "2026-10-10T12:46:00Z"]
    projection["providerTurns"] = turns
    native["projection"] = projection
    #expect(T3V2Presentation.stats(native)?.totalTokens == 42000)
    #expect(T3V2Presentation.stats(native)?.contextIsEstimated != true)
  }

  @Test func latestCompactionWinsRegardlessOfItemOrderAndTimestampPrecision() {
    let items = [compaction(date: "2026-10-10T12:46:00Z", after: 28000), compaction()]
    #expect(T3V2Presentation.stats(snapshot(items: items))?.totalTokens == 28000)
  }

  @Test func unfinishedFailedMissingAndChildCompactionsDoNotChangeMeter() {
    for change: [String: Any] in [
      ["status": "running"], ["status": "failed"], ["status": "cancelled"],
      ["afterTokenCount": NSNull()], ["afterTokenCount": -1],
      ["parentItemId": "subagent-tool"], ["providerTurnId": "child-turn"],
      ["completedAt": "invalid"],
    ] {
      let item = compaction().merging(change) { _, new in new }
      #expect(T3V2Presentation.stats(snapshot(items: [item]))?.totalTokens == 204203)
    }
  }

  @Test func inheritedCompactionNeverReplacesLocalContext() {
    var native = snapshot(items: [])
    var projection = native["projection"] as! [String: Any]
    projection["visibleTurnItems"] = [["visibility": "inherited", "item": compaction()]]
    native["projection"] = projection
    #expect(T3V2Presentation.stats(native)?.totalTokens == 204203)
  }

  @Test func missingContextWindowDoesNotInventPercent() {
    let native: [String: Any] = ["projection": [
      "providerTurns": [["id": "current", "status": "running"]],
      "turnItems": [compaction(after: 0)],
    ]]
    let stats = T3V2Presentation.stats(native)
    #expect(stats?.totalTokens == 0)
    #expect(stats?.contextIsEstimated == true)
    #expect(stats?.contextWindow == nil)
    #expect(stats?.contextPercent == nil)
  }

  @Test func legacyStatsWithoutEstimateFlagStillDecode() throws {
    let data = Data("""
      {"totalTokens":200,"inputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0}
      """.utf8)
    #expect(try JSONDecoder().decode(SessionStats.self, from: data).contextIsEstimated == nil)
  }
}

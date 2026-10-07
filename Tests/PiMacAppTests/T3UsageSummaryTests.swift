import Foundation
import Testing

@testable import PiMacApp

struct T3UsageSummaryTests {
  private func summary(buckets: [[String: Any]], status: String = "ok") -> [String: Any] {
    [
      "contractVersion": 6, "timeZone": "Asia/Shanghai",
      "sinceDay": "2026-01-01", "untilDay": "2026-01-07",
      "buckets": buckets,
      "sources": [["status": status, "distinctSessions": 2]],
    ]
  }

  private func bucket(day: String = "2026-01-01", model: String = "test") -> [String: Any] {
    [
      "day": day, "model": model, "records": 3, "sessions": 2,
      "costUsd": 0.5, "unpricedRecords": 1,
      "totals": ["uncachedInputTokens": 100, "cachedInputTokens": 50,
        "cacheCreationTokens": 10, "outputTokens": 20, "reasoningTokens": 15],
    ]
  }

  @Test func sendsCalendarWindowInReportingTimeZone() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-01-01T20:00:00Z"))
    let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let week = T3UsageSummary.input(period: .week, now: now, timeZone: zone)
    #expect(week["sinceDay"] as? String == "2025-12-27")
    #expect(week["untilDay"] as? String == "2026-01-02")
    #expect(week["timeZone"] as? String == "Asia/Shanghai")
    #expect(week["resolution"] as? String == "day")
    let month = T3UsageSummary.input(period: .month, now: now, timeZone: zone)
    #expect(month["sinceDay"] as? String == "2025-12-04")
    let all = T3UsageSummary.input(period: .all, now: now, timeZone: zone)
    #expect(all["sinceDay"] as? String == "1970-01-01")
  }

  @Test func presentsServerBucketsWithoutDoubleCountingReasoningOrSessions() throws {
    let data = summary(buckets: [bucket(), bucket(day: "2026-01-02", model: "other")])
    let result = try T3UsageSummary.snapshot(data, period: .week)
    #expect(result.totalTokens == 360)
    #expect(result.inputTokens == 200)
    #expect(result.outputTokens == 40)
    #expect(result.cacheReadTokens == 100)
    #expect(result.cacheWriteTokens == 20)
    #expect(result.requests == 6)
    #expect(result.cost == 1)
    #expect(result.sessions == 2) // Not the sum of bucket session counts.
    #expect(result.days.count == 7)
    #expect(result.models.map(\.name) == ["other", "test"])
    #expect(result.projects.isEmpty)
    #expect(result.coverageWarnings.count == 1)
  }

  @Test func partialCoverageAndUnpricedRecordsRemainVisible() throws {
    let result = try T3UsageSummary.snapshot(summary(buckets: [bucket()], status: "partial"), period: .all)
    #expect(result.coverageWarnings.count == 2)
    #expect(result.days.count == 1)
    #expect(result.totalTokens == 180)
  }

  @Test func incompatibleOrMalformedResponsesAreNotPresentedAsZeroUsage() {
    #expect(throws: (any Error).self) { try T3UsageSummary.snapshot([:], period: .month) }
    var data = summary(buckets: [bucket()])
    data["contractVersion"] = 3
    #expect(throws: (any Error).self) { try T3UsageSummary.snapshot(data, period: .month) }
    data["contractVersion"] = 6
    data["buckets"] = [["day": "invalid"]]
    #expect(throws: (any Error).self) { try T3UsageSummary.snapshot(data, period: .month) }
  }

  @MainActor
  @Test func loadFailuresOfferRetryInsteadOfShowingAnEmptyDashboard() async throws {
    var attempts = 0
    let model = UsageDashboardModel { _ in
      attempts += 1
      if attempts == 1 { throw T3DesktopClient.ClientError.unavailable }
      var result = UsageSnapshot()
      result.requests = 4
      return result
    }
    model.reload()
    for _ in 0..<100 where model.isLoading { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!model.isLoading)
    #expect(model.error != nil)
    model.reload()
    for _ in 0..<100 where model.isLoading { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.error == nil)
    #expect(model.snapshot.requests == 4)
  }

  @MainActor
  @Test func cancellationStopsLoadingAndIgnoresLateResults() async throws {
    var response: CheckedContinuation<UsageSnapshot, Never>?
    let model = UsageDashboardModel { _ in
      await withCheckedContinuation { response = $0 }
    }
    model.reload()
    for _ in 0..<100 where response == nil { try await Task.sleep(for: .milliseconds(5)) }
    let pending = try #require(response)
    model.cancel()
    var late = UsageSnapshot()
    late.requests = 99
    pending.resume(returning: late)
    try await Task.sleep(for: .milliseconds(10))
    #expect(!model.isLoading)
    #expect(model.snapshot.requests == 0)
    #expect(model.error != nil)
  }

  @MainActor
  @Test func supersededResponseCannotReplaceNewPeriod() async throws {
    var first: CheckedContinuation<UsageSnapshot, Never>?
    let model = UsageDashboardModel { period in
      if period == .month {
        return await withCheckedContinuation { first = $0 }
      }
      var result = UsageSnapshot()
      result.requests = 7
      return result
    }
    model.reload()
    for _ in 0..<100 where first == nil { try await Task.sleep(for: .milliseconds(5)) }
    let pending = try #require(first)
    model.period = .week
    model.reload()
    for _ in 0..<100 where model.isLoading { try await Task.sleep(for: .milliseconds(5)) }
    var stale = UsageSnapshot()
    stale.requests = 30
    pending.resume(returning: stale)
    try await Task.sleep(for: .milliseconds(10))
    #expect(model.snapshot.requests == 7)
    #expect(!model.isLoading)
  }
}

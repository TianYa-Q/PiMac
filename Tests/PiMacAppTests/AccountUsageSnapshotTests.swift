import Foundation
import Testing

@testable import PiMacApp

struct AccountUsageSnapshotTests {
  @Test func rejectsUntrustedNumbers() {
    let values: [Any] = [true, false, Double.nan, Double.infinity, "50"]
    for value in values {
      #expect(AccountUsageSnapshot.number(value) == nil)
    }
    #expect(AccountUsageSnapshot.percent(-1) == nil)
    #expect(AccountUsageSnapshot.percent(101) == nil)
    #expect(AccountUsageSnapshot.percent(0) == 0)
    #expect(AccountUsageSnapshot.percent(100) == 100)
    #expect(AccountUsageSnapshot.date(-1) == nil)
    #expect(AccountUsageSnapshot.date(1e100) == nil)
    #expect(AccountUsageSnapshot.date(1_000, milliseconds: true)?.timeIntervalSince1970 == 1)
  }

  @Test func freshnessUsesQueryTimeAndHandlesClockChanges() {
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(AccountUsageSnapshot.freshness(capturedAt: nil, now: now) == .unknown)
    #expect(
      AccountUsageSnapshot.freshness(capturedAt: now.addingTimeInterval(-179), now: now) == .fresh)
    #expect(
      AccountUsageSnapshot.freshness(capturedAt: now.addingTimeInterval(-180), now: now) == .stale)
    #expect(
      AccountUsageSnapshot.freshness(capturedAt: now.addingTimeInterval(6), now: now) == .clockSkew)
    #expect(
      AccountUsageSnapshot.freshness(capturedAt: now.addingTimeInterval(2), now: now) == .fresh)
  }

  @MainActor @Test func malformedEnvelopeDoesNotReplaceValidQuotaAndGeminiIDsAreUnique() throws {
    let ui = ExtensionUIModel()
    let source = AppModel(restoreLastProjectOnLaunch: false)
    var payload: [String: Any] = [
      "version": 2, "provider": "openai-codex", "updatedAt": 1_000,
      "accounts": [["name": "work", "primary": ["remainingPercent": 50]]],
      "gemini": [
        "kind": "loaded", "capturedAt": 500,
        "quotas": [
          ["remainingPercent": 50, "window": "5h"],
          ["remainingPercent": 90, "window": "5h"],
          ["remainingPercent": -1, "window": "7d"],
        ],
      ],
    ]
    func publish() throws {
      let text = String(
        decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
      ui.handle(
        [
          "method": "setStatus", "id": "test", "statusKey": "account-usage-gui", "statusText": text,
        ],
        from: source)
    }
    try publish()
    #expect(ui.geminiUsage?.capturedAt == Date(timeIntervalSince1970: 0.5))
    #expect(ui.usage(for: source).gemini?.capturedAt == ui.geminiUsage?.capturedAt)
    #expect(ui.geminiUsage?.quotas.count == 1)
    #expect(ui.geminiUsage?.quotas.first?.remainingPercent == 50)
    payload["accounts"] = [["name": "replacement"]]
    payload["updatedAt"] = true
    try publish()
    #expect(ui.codexAccounts.first?.name == "work")
    payload["updatedAt"] = 2_000
    payload["version"] = true
    try publish()
    #expect(ui.codexAccounts.first?.name == "work")
    ui.handle(
      [
        "method": "setStatus", "id": "oversized", "statusKey": "account-usage-gui",
        "statusText": String(repeating: " ", count: 1_048_577),
      ], from: source)
    #expect(ui.codexAccounts.first?.name == "work")
  }

  @MainActor @Test func payloadDeduplicatesAccountsAndPreservesCaptureTime() throws {
    let ui = ExtensionUIModel()
    let source = AppModel(restoreLastProjectOnLaunch: false)
    let payload: [String: Any] = [
      "version": 2, "provider": "openai-codex", "activeAccount": "work",
      "updatedAt": 10_000,
      "accounts": [
        ["name": "work", "capturedAt": 1_000, "primary": ["remainingPercent": 50]],
        ["name": "work", "primary": ["remainingPercent": 90]],
        ["name": "", "primary": ["remainingPercent": 90]],
        [
          "name": "bad", "primary": ["remainingPercent": true],
          "secondary": ["remainingPercent": 101], "resetCredits": ["availableCount": 1.5],
        ],
      ],
    ]
    let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    ui.selectSource(source)
    ui.handle(
      [
        "method": "setStatus", "id": "snapshot", "statusKey": "account-usage-gui",
        "statusText": text,
      ],
      from: source)
    #expect(ui.codexAccounts.count == 2)
    let work = try #require(ui.codexAccounts.first(where: { $0.name == "work" }))
    #expect(work.capturedAt == Date(timeIntervalSince1970: 1))
    #expect(work.primary?.remainingPercent == 50)
    #expect(
      ui.usage(for: source).accounts.first(where: { $0.name == "work" })?.capturedAt
        == work.capturedAt)
    let bad = try #require(ui.codexAccounts.first(where: { $0.name == "bad" }))
    #expect(bad.primary == nil && bad.secondary == nil && bad.resetCredits == nil)
  }
}

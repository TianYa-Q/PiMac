import Foundation
import Testing

@testable import PiMacApp

struct AccountQuotaPresentationTests {
  let now = Date(timeIntervalSince1970: 1_000)

  private func account(
    _ name: String, percent: Double? = 50, active: Bool = false, hidden: Bool = false,
    age: TimeInterval = 0, error: String? = nil, reset: TimeInterval? = nil
  ) -> CodexAccountStatus {
    CodexAccountStatus(
      name: name, isActive: active, isDefault: false, isHidden: hidden,
      primary: percent.map {
        CodexUsageWindow(
          remainingPercent: $0, resetAt: reset.map { now.addingTimeInterval($0) },
          windowSeconds: 18_000)
      }, secondary: nil, resetCredits: nil, error: error,
      capturedAt: now.addingTimeInterval(-age))
  }

  @Test func filteringIsReadOnlyAndSearchIgnoresCaseAndWhitespace() {
    let rows = [
      account("Work", active: true), account("hidden", hidden: true), account("low", percent: 19),
    ]
    #expect(
      AccountQuotaPresentation.accounts(
        rows, query: " work ", filter: .all, sort: .name, now: now, maxAge: 180
      ).map(\.name) == ["Work"])
    #expect(
      AccountQuotaPresentation.accounts(
        rows, query: "", filter: .visible, sort: .name, now: now, maxAge: 180
      ).map(\.name) == ["Work", "low"])
    #expect(rows[1].isHidden)
    #expect(
      AccountQuotaPresentation.accounts(
        rows, query: "absent", filter: .all, sort: .name, now: now, maxAge: 180
      ).isEmpty)
  }

  @Test func attentionIncludesErrorsUnknownStaleLowAndClockSkewNotHidden() {
    let rows = [
      account("fresh"), account("low", percent: 19), account("boundary", percent: 20),
      account("stale", age: 180), account("unknown", percent: nil),
      account("failed", error: "offline"),
      account("future", age: -6), account("hidden", percent: 0, hidden: true),
    ]
    #expect(
      AccountQuotaPresentation.accounts(
        rows, query: "", filter: .attention, sort: .name, now: now, maxAge: 180
      ).map(\.name) == ["failed", "future", "low", "stale", "unknown"])
    #expect(
      AccountQuotaPresentation.needsAttention(
        account("activeCadence", age: 60), now: now, maxAge: 60))
  }

  @Test func remainingSortPinsActiveAndNeverPromotesStaleOrHiddenTelemetry() {
    let rows = [
      account("stale", percent: 100, age: 180), account("hidden", percent: 100, hidden: true),
      account("low", percent: 10, active: true), account("high", percent: 90),
      account("medium", percent: 50),
    ]
    #expect(
      AccountQuotaPresentation.accounts(
        rows, query: "", filter: .all, sort: .remaining, now: now, maxAge: 180
      ).map(\.name) == ["low", "high", "medium", "hidden", "stale"])
  }

  @Test func resetSortSkipsPastDatesAndUsesNameForStableTies() {
    let rows = [
      account("past", reset: -1), account("later", reset: 120), account("soon2", reset: 60),
      account("soon1", reset: 60), account("missing"),
    ]
    #expect(
      AccountQuotaPresentation.accounts(
        rows, query: "", filter: .all, sort: .reset, now: now, maxAge: 180
      ).map(\.name) == ["soon1", "soon2", "later", "missing", "past"])
  }

  @Test func geminiUsesSameSearchAndAttentionPolicy() {
    let status = GeminiUsageStatus(
      isConfigured: true, isActive: false,
      quotas: [.init(remainingPercent: 80, resetAt: nil, window: nil)], error: nil, capturedAt: now)
    #expect(
      AccountQuotaPresentation.showsGemini(
        status, query: "gemini", filter: .all, now: now, maxAge: 180))
    #expect(
      !AccountQuotaPresentation.showsGemini(
        status, query: "work", filter: .all, now: now, maxAge: 180))
    #expect(
      !AccountQuotaPresentation.showsGemini(
        status, query: "", filter: .attention, now: now, maxAge: 180))
    #expect(
      AccountQuotaPresentation.showsGemini(
        status, query: "", filter: .attention, now: now.addingTimeInterval(180), maxAge: 180))
  }
}

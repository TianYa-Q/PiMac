import Testing

@testable import PiMacApp

struct SessionStatsTests {
  @Test func cacheHitRateUsesAllPromptTokens() {
    let stats = SessionStats(
      cost: 0,
      contextPercent: nil,
      totalTokens: 125,
      inputTokens: 20,
      cacheReadTokens: 75,
      cacheWriteTokens: 5
    )

    #expect(stats.cacheHitPercent == 75)
  }

  @Test func cacheHitRateIsUnavailableWithoutPromptTokens() {
    let stats = SessionStats(
      cost: 0,
      contextPercent: nil,
      totalTokens: 10,
      inputTokens: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0
    )

    #expect(stats.cacheHitPercent == nil)
  }
}

import Foundation

/// Snapshot notifications may arrive many times per second; quota queries must not.
struct AccountQuotaRefreshPolicy {
  private var generation: UUID?
  private var provider: AccountUsageProvider?
  private var lastAttempt: ContinuousClock.Instant?

  mutating func shouldRefresh(
    generation: UUID, provider: AccountUsageProvider, isActive: Bool, force: Bool = false,
    now: ContinuousClock.Instant = .now
  ) -> Bool {
    let interval: Duration = .seconds(isActive ? 60 : 180)
    if !force, self.generation == generation, self.provider == provider,
      let lastAttempt, now - lastAttempt < interval
    {
      return false
    }
    self.generation = generation
    self.provider = provider
    lastAttempt = now
    return true
  }
}

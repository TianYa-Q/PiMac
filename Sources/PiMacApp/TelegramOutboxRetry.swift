import Foundation

/// Drives retry cycles independently of session/UI state. A cycle returns the delay before
/// the next pass, or nil when drained/paused. Cancellation never starts another delivery.
@MainActor
enum TelegramOutboxRetry {
  static func run(
    allowed: () -> Bool, cooldown: () -> Double = { 0 },
    sleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
    cycle: () async -> Double?
  ) async {
    while allowed() && !Task.isCancelled {
      do {
        let wait = cooldown()
        if wait > 0 { try await sleep(wait) }
        guard allowed(), !Task.isCancelled, let delay = await cycle() else { return }
        guard allowed(), !Task.isCancelled else { return }
        if delay > 0 { try await sleep(delay) }
      } catch { return }
    }
  }
}

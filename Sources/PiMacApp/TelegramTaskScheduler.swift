import Foundation

/// Coalesces Published notifications into one deferred drain per runtime. Reset invalidates
/// scheduled work before credential changes or shutdown can affect a different generation.
@MainActor
final class TelegramTaskScheduler {
  private var pending: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var generation = UUID()

  func schedule(for key: ObjectIdentifier, operation: @escaping @MainActor () -> Void) {
    guard pending[key] == nil else { return }
    let generation = generation
    pending[key] = Task { @MainActor [weak self] in
      guard let self, !Task.isCancelled, self.generation == generation else { return }
      self.pending.removeValue(forKey: key)
      operation()
    }
  }

  func reset() {
    generation = UUID()
    for task in pending.values { task.cancel() }
    pending.removeAll()
  }
}

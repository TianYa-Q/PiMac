import Foundation

/// Serialize edits per Telegram message. Navigation invalidates queued automatic edits;
/// an already-sent edit completes before the newer page is sent, never after it.
@MainActor
final class TelegramCardUpdates {
  private var revisions: [Int64: UUID] = [:]
  private var tails: [Int64: (id: UUID, task: Task<Bool, Never>)] = [:]

  func current(_ cardID: Int64) -> UUID {
    if let revision = revisions[cardID] { return revision }
    return advance(cardID)
  }

  @discardableResult
  func advance(_ cardID: Int64) -> UUID {
    let revision = UUID()
    revisions[cardID] = revision
    return revision
  }

  func enqueue(
    _ cardID: Int64, revision: UUID, operation: @escaping @MainActor () async -> Void
  ) -> Task<Bool, Never> {
    let previous = tails[cardID]?.task
    let id = UUID()
    let task = Task { @MainActor [weak self] in
      if let previous { _ = await previous.value }
      guard let self else { return false }
      defer {
        if self.tails[cardID]?.id == id { self.tails.removeValue(forKey: cardID) }
      }
      guard !Task.isCancelled, self.revisions[cardID] == revision else { return false }
      await operation()
      return true
    }
    tails[cardID] = (id, task)
    return task
  }

  func retain(_ cards: Set<Int64>) {
    revisions = revisions.filter { cards.contains($0.key) }
  }

  func reset() {
    revisions.removeAll()
    for tail in tails.values { tail.task.cancel() }
    tails.removeAll()
  }
}

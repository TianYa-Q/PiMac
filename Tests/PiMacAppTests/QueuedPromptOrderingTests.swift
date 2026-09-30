import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct QueuedPromptOrderingTests {
  private func prompt(
    _ text: String, delivery: QueuedPromptDelivery = .followUp,
    deferred: Bool = true
  ) -> QueuedPrompt {
    QueuedPrompt(
      id: UUID(), text: text, rpcText: text, delivery: delivery,
      attachments: [], waitsForCompaction: deferred)
  }

  @Test func deferredPromptsCanMoveInBothDirections() {
    let app = AppModel(restoreLastProjectOnLaunch: false)
    let first = prompt("first")
    let second = prompt("second")
    let third = prompt("third")
    app.queuedPrompts = [first, second, third]

    #expect(app.queuedPromptMoveTarget(id: first.id, direction: -1) == nil)
    #expect(app.queuedPromptMoveTarget(id: third.id, direction: 1) == nil)
    app.moveQueuedPrompt(id: third.id, direction: -1)
    #expect(app.queuedPrompts.map(\.id) == [first.id, third.id, second.id])
    app.moveQueuedPrompt(id: third.id, direction: 1)
    #expect(app.queuedPrompts.map(\.id) == [first.id, second.id, third.id])
  }

  @Test func movesOnlyWithinTheSameDeliveryAndStorageQueue() {
    let app = AppModel(restoreLastProjectOnLaunch: false)
    let first = prompt("duplicate")
    let steering = prompt("steer", delivery: .steer)
    let remote = prompt("remote", deferred: false)
    let second = prompt("duplicate")
    app.queuedPrompts = [first, steering, remote, second]

    #expect(app.queuedPromptMoveTarget(id: second.id, direction: -1) == first.id)
    app.moveQueuedPrompt(id: second.id, direction: -1)
    #expect(app.queuedPrompts.map(\.id) == [second.id, steering.id, remote.id, first.id])
    #expect(app.queuedPromptMoveTarget(id: steering.id, direction: 1) == nil)
    #expect(app.queuedPromptMoveTarget(id: first.id, direction: 0) == nil)
    #expect(app.queuedPromptMoveTarget(id: UUID(), direction: 1) == nil)
  }
}

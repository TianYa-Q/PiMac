import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct TelegramReliabilityTests {
  @Test func classifiesErrorsWithoutRetainingServerDescriptions() {
    func classify(_ status: Int, _ json: String, method: String = "editMessageText")
      -> TelegramAPIError
    {
      TelegramAPI.classify(status: status, data: Data(json.utf8), method: method)
    }
    #expect(classify(429, #"{"parameters":{"retry_after":42}}"#) == .rateLimited(42))
    #expect(classify(401, #"{"description":"secret URL"}"#) == .permanent(401))
    #expect(classify(403, "{}") == .permanent(403))
    #expect(classify(500, "{}") == .failed)
    #expect(
      classify(400, #"{"description":"Bad Request: message is not modified"}"#) == .notModified)
    #expect(
      classify(400, #"{"description":"Bad Request: message to edit not found"}"#)
        == .cardUnavailable)
    #expect(
      classify(400, #"{"description":"Bad Request: can't parse entities"}"#) == .permanent(400))
  }

  @Test func backsOffHonorsRateLimitAndStopsOnPermanentErrors() {
    var policy = TelegramRetryPolicy()
    #expect(policy.delay(for: TelegramAPIError.failed) == 5)
    #expect(policy.delay(for: URLError(.notConnectedToInternet)) == 10)
    #expect(policy.delay(for: TelegramAPIError.rateLimited(90)) == 90)
    #expect(policy.delay(for: TelegramAPIError.permanent(401)) == nil)
    #expect(policy.delay(for: CancellationError()) == nil)
    for _ in 0..<20 { _ = policy.delay(for: TelegramAPIError.failed) }
    #expect(policy.delay(for: TelegramAPIError.failed) == 300)
    policy.reset()
    #expect(policy.delay(for: TelegramAPIError.failed) == 5)
  }

  @Test func resumesOnlyUnsentChunksAndCheckpointsEachSuccess() async throws {
    let text = String(repeating: "a", count: 7001)
    var checkpoint = 0
    var attempted: [String] = []
    do {
      try await TelegramDelivery.sendPieces(
        text, onSent: { _ in checkpoint += 1 },
        transmit: { body in
          attempted.append(body["text"] as! String)
          if attempted.count == 2 { throw TelegramAPIError.failed }
          return 1
        })
      Issue.record("Expected partial delivery failure")
    } catch { #expect(error as? TelegramAPIError == .failed) }
    #expect(checkpoint == 1)
    var resumed: [String] = []
    try await TelegramDelivery.sendPieces(
      text, startingAt: checkpoint, onSent: { _ in checkpoint += 1 },
      transmit: { body in
        resumed.append(body["text"] as! String)
        return 2
      })
    #expect(resumed.map(\.count) == [3500, 1])
    #expect(checkpoint == 3)
    var calls = 0
    try await TelegramDelivery.sendPieces(text, startingAt: checkpoint) { _ in
      calls += 1
      return 3
    }
    #expect(calls == 0)
  }

  @Test func oldPersistedRepliesDecodeAndNewCheckpointsSurviveRestart() throws {
    let id = UUID()
    let json = #"{"id":"\#(id.uuidString)","sessionPath":"/tmp/session","text":"reply"}"#
    let old = try JSONDecoder().decode(TelegramUnsentReply.self, from: Data(json.utf8))
    #expect(old.deliveredChunks == nil)
    var updated = old
    updated.deliveredChunks = 2
    let restored = try JSONDecoder().decode(
      TelegramUnsentReply.self, from: JSONEncoder().encode(updated))
    #expect(restored.deliveredChunks == 2)
    let notice = TelegramPendingNotice(
      id: id, text: "status", keyboard: nil,
      editMessageID: 123, deliveredChunks: 1)
    let restoredNotice = try JSONDecoder().decode(
      TelegramPendingNotice.self, from: JSONEncoder().encode(notice))
    #expect(restoredNotice.editMessageID == 123)
    #expect(restoredNotice.deliveredChunks == 1)
  }

  @Test func editsOnlyCreateNewCardsWhenTheOriginalIsUnavailable() async throws {
    for error in [TelegramAPIError.failed, .rateLimited(30), .permanent(400)] {
      var sends = 0
      do {
        _ = try await TelegramDelivery.editPieces(
          "status", userID: 1, messageID: 42,
          edit: { _ in throw error },
          send: { _ in
            sends += 1
            return 43
          })
        Issue.record("Expected edit error")
      } catch { #expect(error is TelegramAPIError) }
      #expect(sends == 0)
    }
    var starts: [Int] = []
    let replacement = try await TelegramDelivery.editPieces(
      "status", userID: 1, messageID: 42,
      edit: { _ in throw TelegramAPIError.cardUnavailable },
      send: {
        starts.append($0)
        return 43
      })
    #expect(replacement == 43)
    #expect(starts == [0])
    starts.removeAll()
    let unchanged = try await TelegramDelivery.editPieces(
      "status", userID: 1, messageID: 42,
      edit: { _ in throw TelegramAPIError.notModified },
      send: {
        starts.append($0)
        return 43
      })
    #expect(unchanged == 42)
    #expect(starts.isEmpty)
  }

  @Test func outboxHonorsCooldownAndStopsBeforeDeliveryWhenInvalidated() async {
    var waits: [Double] = []
    var calls = 0
    await TelegramOutboxRetry.run(
      allowed: { true }, cooldown: { 3 },
      sleep: { waits.append($0) },
      cycle: {
        calls += 1
        return calls == 1 ? 10 : nil
      })
    #expect(calls == 2)
    #expect(waits == [3, 10, 3])
    var allowed = true
    calls = 0
    await TelegramOutboxRetry.run(
      allowed: { allowed }, cooldown: { 30 },
      sleep: { _ in allowed = false },
      cycle: {
        calls += 1
        return nil
      })
    #expect(calls == 0)
  }

  @Test func schedulerCoalescesAndInvalidatesDeferredDrains() async {
    let scheduler = TelegramTaskScheduler()
    let runtime = NSObject()
    let key = ObjectIdentifier(runtime)
    var calls = 0
    scheduler.schedule(for: key) { calls += 1 }
    scheduler.schedule(for: key) { calls += 100 }
    for _ in 0..<10 { await Task.yield() }
    #expect(calls == 1)
    scheduler.schedule(for: key) { calls += 100 }
    scheduler.reset()
    scheduler.schedule(for: key) { calls += 1 }
    for _ in 0..<10 { await Task.yield() }
    #expect(calls == 2)
  }

  @Test func undeliveredResultsRemainVisibleWithoutALiveRuntime() {
    let project = WorkspaceProject(url: URL(fileURLWithPath: "/tmp/undelivered"))
    let summaries = ProjectStatusOverview.summaries(
      projects: [project], models: [],
      selectedProjectPath: nil, undeliveredCounts: [project.id: 2])
    #expect(ProjectStatusOverview.visibleSummaries(summaries).count == 1)
    #expect(ProjectStatusOverview.message(summaries).contains("2 未送达"))
  }
}

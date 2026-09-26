import Foundation
import Testing
@testable import PiMacApp

@MainActor
struct CodexAccountHandoffTests {
  private final class RPC {
    var commands: [PiRPCClient.JSON] = []
    var callbacks: [(CodexAccountHandoff.Reply) -> Void] = []
    func request(_ command: PiRPCClient.JSON, _ reply: @escaping (CodexAccountHandoff.Reply) -> Void) {
      commands.append(command)
      callbacks.append(reply)
    }
    func reply(_ result: CodexAccountHandoff.Reply = .success([:])) {
      callbacks.removeFirst()(result)
    }
    var types: [String] { commands.compactMap { $0["type"] as? String } }
  }

  @Test func clearsQueueThenWaitsForAbortBeforeSwitchingAndContinuing() {
    let rpc = RPC()
    let handoff = CodexAccountHandoff()
    var preserved = false
    var continued = false
    handoff.start(target: "B", interrupt: true, request: rpc.request,
      preserveQueue: { data in
        preserved = (data["steering"] as? [String]) == ["pending instruction"]
      }, verifyAccount: { true }, completion: { result in
        if case .success = result { continued = true }
      })
    #expect(rpc.types == ["clear_queue"])
    rpc.reply(.success(["data": ["steering": ["pending instruction"], "followUp": ["later"]]]))
    #expect(preserved)
    #expect(rpc.types == ["clear_queue", "abort"])
    #expect(!continued)
    rpc.reply()
    #expect(rpc.types == ["clear_queue", "abort", "prompt"])
    #expect(rpc.commands.last?["message"] as? String == "/accounts switch B")
    #expect(!continued)
    rpc.reply()
    #expect(continued)
  }

  @Test func idleSwitchDoesNotAbort() {
    let rpc = RPC()
    let handoff = CodexAccountHandoff()
    handoff.start(target: "B", interrupt: false, request: rpc.request,
      preserveQueue: { _ in Issue.record("Idle queue should not be cleared") },
      verifyAccount: { true }, completion: { _ in })
    #expect(rpc.types == ["prompt"])
  }

  @Test func manualStopPreservesQueueAndStopsWithoutSwitching() {
    let rpc = RPC()
    let handoff = CodexAccountHandoff()
    var preserved = false
    var cancelled = false
    handoff.start(target: "B", interrupt: true, request: rpc.request,
      preserveQueue: { _ in preserved = true }, verifyAccount: { true },
      completion: { if case .failure(let error) = $0 { cancelled = error is CancellationError } })
    handoff.cancel()
    rpc.reply(.success(["data": ["steering": ["keep me"], "followUp": []]]))
    rpc.reply()
    #expect(preserved)
    #expect(cancelled)
    #expect(rpc.types == ["clear_queue", "abort"])
  }

  @Test func cancellationDuringSwitchDoesNotContinue() {
    let rpc = RPC()
    let handoff = CodexAccountHandoff()
    var cancelled = false
    handoff.start(target: "B", interrupt: false, request: rpc.request,
      preserveQueue: { _ in }, verifyAccount: { true },
      completion: { if case .failure(let error) = $0 { cancelled = error is CancellationError } })
    handoff.cancel()
    rpc.reply()
    #expect(cancelled)
  }

  @Test func unconfirmedAccountAndRPCFailuresDoNotContinue() {
    for stage in 0...3 {
      let rpc = RPC()
      let handoff = CodexAccountHandoff()
      var failed = false
      handoff.start(target: "B", interrupt: true, request: rpc.request,
        preserveQueue: { _ in }, verifyAccount: { false },
        completion: { if case .failure = $0 { failed = true } })
      if stage > 0 { rpc.reply(.success(["data": ["steering": [], "followUp": []]])) }
      if stage > 1 { rpc.reply() }
      if stage == 3 { rpc.reply() }
      else { rpc.reply(.failure(NSError(domain: "test", code: stage))) }
      #expect(failed)
      #expect(rpc.commands.count == min(stage + 1, 3))
    }
  }

  @Test func processReplacementIgnoresOldCallbacks() {
    let rpc = RPC()
    let handoff = CodexAccountHandoff()
    handoff.start(target: "B", interrupt: true, request: rpc.request,
      preserveQueue: { _ in Issue.record("Stale queue") }, verifyAccount: { true },
      completion: { _ in Issue.record("Stale continuation") })
    handoff.reset()
    rpc.reply(.success(["data": ["steering": [], "followUp": []]]))
    #expect(rpc.types == ["clear_queue"])
  }
}

import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct DesktopResponsivenessTests {
  private final class Gate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() {
      continuation?.resume()
      continuation = nil
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func slowThreadDoesNotBlockAnotherAndRepeatedRequestsUseNewestWork() async throws {
    let scheduler = ThreadRefreshScheduler()
    let gate = Gate()
    var calls: [String] = []
    let slow = scheduler.request("slow") {
      calls.append("slow-start")
      await gate.wait()
    }
    for _ in 0..<1000 where gate.continuation == nil { await Task.yield() }
    try #require(gate.continuation != nil)
    defer {
      gate.open()
      scheduler.cancelAll()
    }
    let fast = scheduler.request("fast") { calls.append("fast") }
    try await fast.value
    #expect(calls == ["slow-start", "fast"])
    scheduler.request("slow") { calls.append("stale") }
    scheduler.request("slow") { calls.append("newest") }
    gate.open()
    try await slow.value
    #expect(calls == ["slow-start", "fast", "newest"])
  }

  @Test func failedLaneCanRefreshAgainWithoutBlockingOtherThreads() async throws {
    let scheduler = ThreadRefreshScheduler()
    let failed = scheduler.request("failed") { throw CocoaError(.fileReadUnknown) }
    let healthy = scheduler.request("healthy") {}
    do {
      try await failed.value
      Issue.record("刷新失败不能当作合法空状态")
    } catch {}
    try await healthy.value
    var recovered = false
    try await scheduler.request("failed") { recovered = true }.value
    #expect(recovered)
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellationDoesNotRemoveReplacementLane() async throws {
    let scheduler = ThreadRefreshScheduler()
    let gate = Gate()
    let old = scheduler.request("same") { await gate.wait() }
    for _ in 0..<1000 where gate.continuation == nil { await Task.yield() }
    try #require(gate.continuation != nil)
    scheduler.cancelAll()
    var count = 0
    let replacement = scheduler.request("same") { count += 1 }
    gate.open()
    try? await old.value
    try await replacement.value
    #expect(count == 1)
    try await scheduler.request("same") { count += 1 }.value
    #expect(count == 2)
  }

  private func submissionModel() -> (AppModel, T3DesktopClient) {
    let client = T3DesktopClient()
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.attach(to: client)
    model.projectURL = URL(fileURLWithPath: "/tmp/pimac-responsiveness")
    model.currentSessionPath = "t3:test-thread"
    model.connectionState = .connected
    model.isLoadingConfiguration = false
    model.isStreaming = true
    client.didCompletePoll()
    return (model, client)
  }

  @Test func queuedSubmissionStaysOutOfTimelineAndHandsOffByMessageIdentity() throws {
    let (model, client) = submissionModel()
    defer {
      model.disconnect()
      client.stop()
    }
    model.composerText = "identical text"
    model.sendPrompt(delivery: .followUp)
    #expect(model.composerText.isEmpty)
    #expect(model.messages.isEmpty)
    let pending = try #require(model.queuedPrompts.first)
    #expect(pending.submissionState == .submitting)
    #expect(model.queuedPromptMoveTarget(id: pending.id, direction: -1) == nil)
    let messageID = String(pending.id.dropFirst("pending:".count))
    // 同样的文字不是确认依据；只有 Server 返回同一个消息身份才交接。
    model.apply([
      "thread": [
        "id": "test-thread",
        "queuedMessages": [
          ["runId": "other-run", "messageId": "other-message", "text": "identical text"]
        ],
      ]
    ])
    #expect(model.queuedPrompts.count == 2)
    model.apply([
      "thread": [
        "id": "test-thread",
        "queuedMessages": [
          ["runId": "real-run", "messageId": messageID, "text": "identical text"]
        ],
      ]
    ])
    #expect(model.queuedPrompts.count == 1)
    #expect(model.queuedPrompts.first?.id == "real-run")
    #expect(model.queuedPrompts.first?.submissionState == .confirmed)
    #expect(model.messages.isEmpty)
    model.apply([
      "thread": [
        "id": "test-thread",
        "messages": [
          ["id": "native-item", "messageId": messageID, "role": "user", "text": "identical text"]
        ],
      ]
    ])
    #expect(model.queuedPrompts.isEmpty)
    #expect(model.messages.map(\.id) == [messageID])
  }

  @Test(.timeLimit(.minutes(1)))
  func failedQueuedUploadRemainsUnconfirmedWithoutClearingNewDraft() async throws {
    let (model, client) = submissionModel()
    defer {
      model.disconnect()
      client.stop()
    }
    model.composerText = "missing image"
    model.attachments = [
      PromptAttachment(
        url: URL(fileURLWithPath: "/tmp/pimac-missing-\(UUID().uuidString).png"),
        mimeType: "image/png")
    ]
    model.sendPrompt(delivery: .followUp)
    model.composerText = "new draft"
    for _ in 0..<200 where !model.canSubmitPrompt {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.queuedPrompts.first?.submissionState == .unconfirmed)
    #expect(model.queuedPrompts.first?.attachments.count == 1)
    #expect(model.messages.isEmpty)
    #expect(model.composerText == "new draft")
  }

  @Test func oldAssetCompletionCannotRollBackNewerTextOrConfirmInvalidatedSubscription() throws {
    var text = ""
    let observer = T3DesktopClient.ThreadWatch(
      threadID: "thread", receive: { text = $0["text"] as? String ?? "" }, receiveUI: { _ in })
    let old = Data([1])
    let newest = Data([2])
    observer.deliver(["text": "old"], fingerprint: old, complete: false)
    observer.deliver(["text": "newest"], fingerprint: newest, complete: false)
    observer.deliverAssets(["text": "stale assets"], fingerprint: old, complete: true)
    #expect(text == "newest")
    #expect(observer.deliveredSnapshot == nil)
    observer.deliverAssets(["text": "newest with assets"], fingerprint: newest, complete: true)
    #expect(text == "newest with assets")
    #expect(observer.deliveredSnapshot == newest)
    observer.invalidate()
    observer.deliverAssets(["text": "invalidated"], fingerprint: newest, complete: true)
    #expect(text == "newest with assets")
    #expect(observer.deliveredSnapshot == nil)
  }

  @Test func backgroundJSONParsingRejectsNonObjectAndKeepsCanonicalIdentity() async throws {
    let empty = try await ImmutableJSONSnapshot.decode(Data("{}".utf8))
    #expect(empty.value.isEmpty)
    let first = try await ImmutableJSONSnapshot.decode(Data(#"{"b":2,"a":1}"#.utf8))
    let second = try await ImmutableJSONSnapshot.decode(Data(#"{"a":1,"b":2}"#.utf8))
    #expect(try await first.fingerprint() == second.fingerprint())
    let encoded = try await first.encode()
    #expect(try await ImmutableJSONSnapshot.decode(encoded).fingerprint() == first.fingerprint())
    let batch = try await ImmutableJSONSnapshot.frames(
      Data(#"[{"_tag":"Ping"},{"_tag":"Exit"}]"#.utf8))
    #expect(batch.map { $0.value["_tag"] as? String } == ["Ping", "Exit"])
    #expect(try await ImmutableJSONSnapshot.frames(Data(#"{"_tag":"Ping"}"#.utf8)).count == 1)
    for invalid in ["[]", "broken"] {
      do {
        _ = try await ImmutableJSONSnapshot.decode(Data(invalid.utf8))
        Issue.record("损坏的响应不能被当成空列表")
      } catch {}
    }
  }

  @Test func cacheOnlyToolPassDoesNotStartIOOrAcknowledgeMissingOutput() async throws {
    let client = T3DesktopClient()
    let snapshot: [String: Any] = [
      "projection": [
        "visibleTurnItems": [
          [
            "item": [
              "id": "item", "type": "dynamic_tool", "status": "completed",
              "updatedAt": "revision", "outputOmitted": true, "toolName": "read",
            ]
          ]
        ]
      ]
    ]
    let (_, complete) = await client.hydrateToolImages(
      snapshot, threadID: "thread", base: URL(string: "http://127.0.0.1:9999")!,
      performRPC: { _, _ in
        Issue.record("缓存阶段不能发起 RPC")
        return [:]
      },
      loadHTML: { _ in
        Issue.record("缓存阶段不能下载 HTML")
        return ""
      }, cachedOnly: true)
    #expect(!complete)
    var calls = 0
    let (_, hydrated) = await client.hydrateToolImages(
      snapshot, threadID: "thread", base: URL(string: "http://127.0.0.1:9999")!,
      performRPC: { _, _ in
        calls += 1
        return ["item": ["output": ["content": [["type": "text", "text": "done"]]]]]
      }, loadHTML: { _ in "" })
    #expect(hydrated)
    #expect(calls == 1)
    let (_, cached) = await client.hydrateToolImages(
      snapshot, threadID: "thread", base: URL(string: "http://127.0.0.1:9999")!,
      performRPC: { _, _ in
        Issue.record("完整缓存不能重复读取")
        return [:]
      },
      loadHTML: { _ in
        Issue.record("完整缓存不能重新下载")
        return ""
      }, cachedOnly: true)
    #expect(cached)
  }

  @Test func imagePayloadEncodingPreservesBytesAndRejectsMissingFiles() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/desktop-performance/encoding-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("image.png")
    let bytes = Data([0, 1, 2, 255])
    try bytes.write(to: file)
    let payload = try await PromptImagePayload.encode([
      PromptAttachment(url: file, mimeType: "image/png"),
      PromptAttachment(url: root.appendingPathComponent("not-read.txt"), mimeType: "text/plain"),
    ])
    #expect(payload.count == 1)
    #expect(payload.first?.sizeBytes == bytes.count)
    #expect(payload.first?.dataURL == "data:image/png;base64,\(bytes.base64EncodedString())")
    do {
      _ = try await PromptImagePayload.encode([
        PromptAttachment(url: root.appendingPathComponent("missing.png"), mimeType: "image/png")
      ])
      Issue.record("不存在的图片必须失败，不能静默丢失附件")
    } catch {}
  }
}

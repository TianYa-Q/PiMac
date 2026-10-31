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

  @Test(.timeLimit(.minutes(1)))
  func foregroundWritesCancelSlowReadsAndNestedHoldsPreventPollRestart() async throws {
    let scheduler = ThreadRefreshScheduler()
    var started = false
    var cancelled = false
    var followUpReads = 0
    let slow = scheduler.request("large-transcript") {
      started = true
      do { try await Task.sleep(for: .seconds(30)) } catch {
        cancelled = true
        throw error
      }
    }
    for _ in 0..<1000 where !started { await Task.yield() }
    try #require(started)
    let firstWrite = scheduler.suspend()
    let secondWrite = scheduler.suspend()
    do {
      try await slow.value
      Issue.record("前台提交必须取消慢读取，不能等它自然超时")
    } catch is CancellationError {} catch { Issue.record("非预期刷新错误：\(error)") }
    #expect(cancelled)
    for token in [firstWrite, secondWrite] {
      // 模拟写入中定时轮询；取消不是刷新成功，且不能重新占住 Server。
      let skipped = scheduler.request("large-transcript") { followUpReads += 1 }
      do {
        try await skipped.value
        Issue.record("暂停期间不能伪报刷新成功")
      } catch is CancellationError {} catch { Issue.record("非预期刷新错误：\(error)") }
      #expect(followUpReads == 0)
      scheduler.resume(token)
    }
    #expect(!scheduler.isSuspended)
    try await scheduler.request("large-transcript") { followUpReads += 1 }.value
    #expect(followUpReads == 1)
  }

  @Test func lateMutationCompletionCannotReleaseNewConnectionReadHold() async throws {
    let scheduler = ThreadRefreshScheduler()
    let old = scheduler.suspend()
    scheduler.cancelAll()  // 断线/停止必须释放旧连接的暂停状态。
    #expect(!scheduler.isSuspended)
    let current = scheduler.suspend()
    scheduler.resume(old)
    #expect(scheduler.isSuspended)
    scheduler.resume(current)
    #expect(!scheduler.isSuspended)
    var reads = 0
    try await scheduler.request("new-connection") { reads += 1 }.value
    #expect(reads == 1)
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

  @Test func blockedEnterExplainsReasonAndPreservesDraftAndAttachments() {
    let (model, client) = submissionModel()
    defer {
      model.disconnect()
      client.stop()
    }
    model.isStreaming = false
    model.isLoadingConfiguration = true
    model.composerText = "keep draft"
    let image = PromptAttachment(
      url: URL(fileURLWithPath: "/tmp/not-uploaded.png"), mimeType: "image/png")
    model.attachments = [image]
    #expect(!model.canSubmitPrompt)
    #expect(model.promptSubmissionUnavailableReason != nil)
    model.sendPrompt()
    #expect(model.statusText == model.promptSubmissionUnavailableReason)
    #expect(model.composerText == "keep draft")
    #expect(model.attachments.map(\.id) == [image.id])
    #expect(model.messages.isEmpty)
    model.isLoadingConfiguration = false
    #expect(model.canSubmitPrompt)
    #expect(model.promptSubmissionUnavailableReason == nil)
    model.isCompacting = true
    model.sendPrompt()
    #expect(model.statusText == model.promptSubmissionUnavailableReason)
    #expect(model.composerText == "keep draft")
  }

  private func draftClient() throws -> T3DesktopClient {
    // 不从真实桌面缓存读取历史线程，确保断言只针对本次操作。
    let defaults = try #require(UserDefaults(suiteName: "draft-readiness-\(UUID().uuidString)"))
    let client = T3DesktopClient(defaults: defaults)
    client.applyProviderCatalog(
      [
        ["instanceId": "pi", "models": [["slug": "test/model", "name": "Test"]]]
      ], modelCatalogs: [:])
    return client
  }

  @Test func connectedNewDraftIsReadySynchronouslyWithoutCreatingThread() throws {
    let client = try draftClient()
    client.didCompletePoll()
    let model = AppModel(startupProjectURL: URL(fileURLWithPath: "/tmp/new-draft"))
    defer {
      model.disconnect()
      client.stop()
    }
    model.attach(to: client)
    #expect(model.canSubmitPrompt)
    #expect(!model.isLoadingConfiguration)
    #expect(model.connectionState == .connected)
    #expect(model.selectedModelId == "test/model")
    #expect(model.threadID == nil)
    #expect(client.threads.isEmpty)
  }

  @Test func failedDraftRecoversWhenServerBecomesReadyWithoutLosingInput() async throws {
    let client = try draftClient()
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.attach(to: client)
    model.projectURL = URL(fileURLWithPath: "/tmp/recovered-draft")
    model.connectionState = .failed("connection timed out")
    model.composerText = "unsent draft"
    defer {
      model.disconnect()
      client.stop()
    }
    client.didCompletePoll()
    for _ in 0..<100 where !model.canSubmitPrompt { await Task.yield() }
    #expect(model.canSubmitPrompt)
    #expect(model.composerText == "unsent draft")
    #expect(model.threadID == nil)
    #expect(client.threads.isEmpty)
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
  func missingAttachmentFailsBeforeSubmissionAndPreservesComposer() async throws {
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
    #expect(model.composerText == "missing image")
    #expect(model.attachments.count == 1)
    #expect(model.queuedPrompts.isEmpty)
    #expect(model.messages.isEmpty)
    #expect(model.deliveryStorageFailure != nil)
    #expect(model.deliveryCoordinator?.store.messages.isEmpty == true)
    model.composerText = "new draft"
    await Task.yield()
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
    let (_, complete, _) = await client.hydrateToolImages(
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
    let (_, hydrated, _) = await client.hydrateToolImages(
      snapshot, threadID: "thread", base: URL(string: "http://127.0.0.1:9999")!,
      performRPC: { _, _ in
        calls += 1
        return ["item": ["output": ["content": [["type": "text", "text": "done"]]]]]
      }, loadHTML: { _ in "" })
    #expect(hydrated)
    #expect(calls == 1)
    let (_, cached, _) = await client.hydrateToolImages(
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

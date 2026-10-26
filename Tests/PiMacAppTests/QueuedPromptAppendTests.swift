import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct QueuedPromptAppendTests {
  @Test func numberingPreservesMultilineInputAndContinuesExistingBatch() {
    let second = T3DesktopClient.appendingQueuedText("第一个\n补充说明", "第二个")
    #expect(second == "1. 第一个\n补充说明\n2. 第二个")
    #expect(
      T3DesktopClient.appendingQueuedText(second, "第三个\n详细说明")
        == "1. 第一个\n补充说明\n2. 第二个\n3. 第三个\n详细说明")
    #expect(T3DesktopClient.appendingQueuedText("1. 用户自己的单项", "新增") == "1. 1. 用户自己的单项\n2. 新增")
  }

  @Test(.timeLimit(.minutes(2)))
  func additionsEditOneServerRunAndSendOnceWithImages() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/queue-batch/swift-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fixture = repository.appendingPathComponent("sidecars/t3-server/tests/fixtures/pi.mjs")
    let binary = root.appendingPathComponent("fixture-pi")
    try "#!/bin/sh\nexec node \"\(fixture.path)\" \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let defaults = try #require(UserDefaults(suiteName: "queue-append-\(UUID().uuidString)"))
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let workspace = WorkspaceModel(restoreUserState: false)
    let state = root.appendingPathComponent("state")
    let service = T3BridgeService(defaults: defaults, stateDirectory: state)
    let client = T3DesktopClient(defaults: defaults)
    let model = AppModel(startupProjectURL: root, continueLastSession: false)
    defer {
      model.disconnect()
      client.stop()
      service.stop()
      workspace.disconnectAll()
    }
    try startT3ProtocolFixture(
      service: service, workspace: workspace, stateDirectory: state,
      binary: binary, model: "test/model")
    client.start(service: service)
    try await client.waitUntilReady()
    model.attach(to: client)
    try await wait { model.canSubmitPrompt }
    model.changeModel(to: "test/model")
    try await wait { !model.isBusy }
    // 交互 fixture 提供确定性的运行屏障，不依赖固定时长的 slow 回合。
    model.composerText = "dialog"
    model.sendPrompt()
    try await wait { model.isStreaming && model.canSubmitPrompt }
    let threadID = try #require(model.threadID)
    model.composerText = "第一条\n详情"
    model.sendPrompt(delivery: .followUp)
    try await wait {
      model.canSubmitPrompt && model.queuedPrompts.count == 1
        && model.queuedPrompts.first?.submissionState == .confirmed
    }
    let firstRunID = try #require(model.queuedPrompts.first?.id)
    let image = root.appendingPathComponent("queued.png")
    try #require(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jL1cAAAAASUVORK5CYII="
      )
    )
    .write(to: image)
    model.attachments = [PromptAttachment(url: image, mimeType: "image/png")]
    model.composerText = "第二条"
    model.sendPrompt(delivery: .followUp)
    try await wait {
      model.canSubmitPrompt && model.queuedPrompts.count == 1
        && model.queuedPrompts.first?.text == "1. 第一条\n详情\n2. 第二条"
    }
    model.composerText = "第三条"
    model.sendPrompt(delivery: .followUp)
    let expected = "1. 第一条\n详情\n2. 第二条\n3. 第三条"
    try await wait {
      model.canSubmitPrompt && model.queuedPrompts.count == 1
        && model.queuedPrompts.first?.text == expected
    }
    #expect(model.queuedPrompts.first?.id == firstRunID)
    let snapshot = try await client.request("/api/orchestration/threads/\(threadID)")
    try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appendingPathComponent("snapshot.json"))
    let projection = try #require(snapshot["projection"] as? [String: Any])
    let runs = try #require(projection["runs"] as? [[String: Any]])
    #expect(runs.filter { $0["status"] as? String == "queued" }.count == 1)
    let messages = try #require(projection["messages"] as? [[String: Any]])
    let merged = try #require(messages.first { $0["text"] as? String == expected })
    #expect((merged["attachments"] as? [[String: Any]])?.count == 1)
    // 运行身份可先于 Provider 的交互事件到达，不能拿此前快照推断请求已发布。
    var requestProjection = projection
    for _ in 0..<200 {
      if (requestProjection["runtimeRequests"] as? [[String: Any]])?.contains(where: {
        $0["status"] as? String == "pending"
      }) == true {
        break
      }
      try await Task.sleep(for: .milliseconds(25))
      let latest = try await client.request("/api/orchestration/threads/\(threadID)")
      requestProjection = try #require(latest["projection"] as? [String: Any])
    }
    let requests = try #require(requestProjection["runtimeRequests"] as? [[String: Any]])
    let request = try #require(requests.first { $0["status"] as? String == "pending" })
    let requestID = try #require(request["id"] as? String)
    let items = try #require(requestProjection["turnItems"] as? [[String: Any]])
    let input = try #require(items.first { $0["requestId"] as? String == requestID })
    let questions = try #require(input["questions"] as? [[String: Any]])
    let questionID = try #require(questions.first?["id"] as? String)
    try await client.dispatch([
      "type": "runtime-request.respond", "threadId": threadID, "requestId": requestID,
      "answers": [questionID: "continue"],
    ])
    try await wait {
      model.messages.contains { $0.kind == .assistant && $0.text == "Reply: \(expected)" }
    }
    #expect(model.queuedPrompts.isEmpty)
    let records = try String(
      contentsOf: root.appendingPathComponent("fixture-rpc.ndjson"), encoding: .utf8
    )
    .split(separator: "\n").map {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
    // 标题生成使用独立只读进程，不属于会话的用户回合。
    let prompts = records.filter {
      $0["command"] as? String == "prompt" && $0["streamingBehavior"] != nil
    }
    #expect(prompts.count == 2)
    #expect(prompts.last?["message"] as? String == expected)
    #expect(prompts.last?["imageCount"] as? Int == 1)
  }

  private func wait(
    sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool
  ) async throws {
    for _ in 0..<400 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    try #require(
      predicate(), "Timed out waiting for authoritative queue state", sourceLocation: sourceLocation
    )
  }
}

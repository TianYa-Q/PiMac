import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct MessageRecoveryIntegrationTests {
  /// 在真实 Server 已提交后丢弃响应；不替代写入、数据库或 Provider 路径。
  private final class LostReplyTransport: MessageDeliveryTransport {
    let client: T3DesktopClient
    var loseReply = true
    var hideMessages = false
    var dispatchIDs: [String] = []
    var snapshotFailures = 0
    var attachmentBatches = 0
    init(client: T3DesktopClient) { self.client = client }
    func recoveryEnvironmentID() async throws -> String { try await client.recoveryEnvironmentID() }
    func recoveryProjectID(_ url: URL) async throws -> String? {
      try await client.recoveryProjectID(url)
    }
    func recoverySnapshot(threadID: String) async throws -> [String: Any] {
      if snapshotFailures > 0 {
        snapshotFailures -= 1
        throw URLError(.timedOut)
      }
      var snapshot = try await client.recoverySnapshot(threadID: threadID)
      if hideMessages, var projection = snapshot["projection"] as? [String: Any] {
        projection["messages"] = [[String: Any]]()
        snapshot["projection"] = projection
      }
      return snapshot
    }
    func ensureProject(_ url: URL) async throws -> String { try await client.ensureProject(url) }
    func persistAttachments(_ images: [[String: Any]], threadID: String, messageID: String)
      async throws -> [[String: Any]]
    {
      if !images.isEmpty { attachmentBatches += 1 }
      return try await client.persistAttachments(images, threadID: threadID, messageID: messageID)
    }
    func dispatch(_ fields: [String: Any], commandID: String, refreshAfter: Bool) async throws
      -> [String: Any]
    {
      let result = try await client.dispatch(
        fields, commandID: commandID, refreshAfter: refreshAfter)
      if fields["type"] as? String == "message.dispatch" {
        dispatchIDs.append(commandID)
        if loseReply {
          loseReply = false
          throw URLError(.networkConnectionLost)
        }
      }
      return result
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func realServerReceiptSurvivesRestartAndMissingThreadRemainsRecoverable() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent(
      "tmp/delivery-recovery/server-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fixture = repository.appendingPathComponent("sidecars/t3-server/tests/fixtures/pi.mjs")
    let binary = root.appendingPathComponent("fixture-pi")
    try "#!/bin/sh\nexec node \"\(fixture.path)\" \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "delivery-recovery-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let workspace = WorkspaceModel(restoreUserState: false)
    let state = root.appendingPathComponent("state")
    let service = T3BridgeService(defaults: defaults, stateDirectory: state)
    let client = T3DesktopClient(defaults: defaults)
    defer {
      client.stop()
      service.stop()
      workspace.disconnectAll()
      defaults.removePersistentDomain(forName: suite)
    }
    func start() async throws {
      try startT3ProtocolFixture(
        service: service, workspace: workspace, stateDirectory: state, binary: binary,
        model: "test/model")
      client.start(service: service)
      try await client.waitUntilReady()
    }
    try await start()
    let transport = LostReplyTransport(client: client)
    let location = root.appendingPathComponent("outbox")
    let store = MessageOutboxStore(directory: location)
    let record = try store.save(
      prompt: #require(
        AppModel.makePrompt("recover exactly once", attachments: [], delivery: .steer)),
      messageID: UUID().uuidString, threadID: UUID().uuidString, project: root,
      selection: ["instanceId": "pi", "model": "test/model"], createsThread: true, context: "")
    let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
    #expect(await coordinator.deliver(record.id) == false)
    #expect(store.message(record.id)?.state == .unknown)
    try await wait {
      let projection =
        try await client.recoverySnapshot(threadID: record.threadID)["projection"] as? [String: Any]
      return (projection?["runs"] as? [[String: Any]])?.contains {
        $0["status"] as? String == "completed"
      } == true
    }
    client.stop()
    service.stop()
    try await wait { !service.isStopping }
    try await start()
    // 模拟重启后的快照滞后，强制走同 ID 官方回执重放，而不是仅按正文去重。
    transport.hideMessages = true
    let reloaded = MessageOutboxStore(directory: location)
    let recovery = MessageRecoveryCoordinator(store: reloaded, transport: transport)
    #expect(await recovery.check(record.id) == .ready)
    #expect(transport.dispatchIDs.count == 1)
    #expect(await recovery.deliver(record.id))
    #expect(transport.dispatchIDs == [record.dispatchCommandID, record.dispatchCommandID])
    transport.hideMessages = false
    let result = try await client.recoverySnapshot(threadID: record.threadID)
    let projection = try #require(result["projection"] as? [String: Any])
    let runs = try #require(projection["runs"] as? [[String: Any]])
    let messages = try #require(projection["messages"] as? [[String: Any]])
    #expect(runs.count == 1)
    #expect(messages.filter { $0["id"] as? String == record.id }.count == 1)
    let log = try String(
      contentsOf: root.appendingPathComponent("fixture-rpc.ndjson"), encoding: .utf8)
    let prompts = try log.split(separator: "\n").map {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }.filter {
      $0["command"] as? String == "prompt" && $0["message"] as? String == "recover exactly once"
    }
    #expect(prompts.count == 1, "真实 Provider 只能执行一次")

    // 带图预检超时后安全重试；实际上传一次，丢失提交回执后仍按原身份重放。
    let image = root.appendingPathComponent("attachment.png")
    try #require(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )
    ).write(to: image)
    let automatic = try reloaded.save(
      prompt: #require(
        AppModel.makePrompt(
          "automatic recovery once",
          attachments: [PromptAttachment(url: image, mimeType: "image/png")], delivery: .followUp)),
      messageID: UUID().uuidString, threadID: record.threadID, project: root,
      selection: ["instanceId": "pi", "model": "test/model"], createsThread: false, context: "")
    transport.loseReply = true
    transport.hideMessages = true
    transport.snapshotFailures = 1
    #expect(await recovery.deliver(automatic.id, retryDelays: [.zero, .zero]))
    #expect(transport.attachmentBatches == 1)
    #expect(
      Array(transport.dispatchIDs.suffix(2)) == [
        automatic.dispatchCommandID, automatic.dispatchCommandID,
      ])
    transport.hideMessages = false
    try await wait {
      let log = try String(
        contentsOf: root.appendingPathComponent("fixture-rpc.ndjson"), encoding: .utf8)
      return log.contains("automatic recovery once")
    }
    let automaticSnapshot = try await client.recoverySnapshot(threadID: record.threadID)
    let automaticProjection = try #require(automaticSnapshot["projection"] as? [String: Any])
    let automaticMessages = try #require(automaticProjection["messages"] as? [[String: Any]])
    #expect(automaticMessages.filter { $0["id"] as? String == automatic.id }.count == 1)
    let automaticMessage = try #require(
      automaticMessages.first { $0["id"] as? String == automatic.id })
    #expect((automaticMessage["attachments"] as? [[String: Any]])?.count == 1)
    let automaticRuns = try #require(automaticProjection["runs"] as? [[String: Any]])
    #expect(automaticRuns.count == 2)
    let automaticLog = try String(
      contentsOf: root.appendingPathComponent("fixture-rpc.ndjson"), encoding: .utf8)
    let automaticPrompts = try automaticLog.split(separator: "\n").map {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }.filter {
      $0["command"] as? String == "prompt"
        && $0["message"] as? String == "automatic recovery once"
    }
    #expect(automaticPrompts.count == 1)

    let missingID = UUID().uuidString
    do {
      try await client.dispatch([
        "type": "message.dispatch", "threadId": missingID, "messageId": UUID().uuidString,
        "text": "missing", "attachments": [],
        "modelSelection": ["instanceId": "pi", "model": "test/model"],
        "dispatchMode": ["type": "queue_after_active"],
      ])
      Issue.record("不存在的线程必须明确失败")
    } catch let failure as T3DesktopClient.RPCFailure {
      #expect(failure.threadMissing, "真实 RPC Failure 必须保留嵌套错误类型")
    }
    let orphan = try reloaded.save(
      prompt: #require(AppModel.makePrompt("迁移这条原稿", attachments: [], delivery: .followUp)),
      messageID: UUID().uuidString, threadID: missingID, project: root,
      selection: ["instanceId": "pi", "model": "test/model"], createsThread: false,
      context: "助手：已知资料")
    #expect(await recovery.check(orphan.id) == .missing)
    let target = try reloaded.migrate([#require(reloaded.message(orphan.id))])
    #expect(await recovery.deliver(target.id))
    let targetSnapshot = try await client.recoverySnapshot(threadID: target.threadID)
    let targetProjection = try #require(targetSnapshot["projection"] as? [String: Any])
    let migrated = try #require(targetProjection["messages"] as? [[String: Any]])
    #expect(migrated.contains { ($0["text"] as? String)?.contains("迁移这条原稿") == true })
    #expect(reloaded.message(orphan.id)?.migratedTo == target.id)
  }

  private func wait(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<400 {
      if try await predicate() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Timed out waiting for isolated Server state")
    throw URLError(.timedOut)
  }
}

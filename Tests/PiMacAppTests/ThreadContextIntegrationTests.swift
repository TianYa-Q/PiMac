import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ThreadContextIntegrationTests {
  @Test(.timeLimit(.minutes(3)))
  func officialClipboardOutboxServerProjectionAndProviderPreserveThreadPayload() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent(
      "tmp/desktop-thread-context/server-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fixture = repository.appendingPathComponent("sidecars/t3-server/tests/fixtures/pi.mjs")
    let binary = root.appendingPathComponent("fixture-pi")
    try "#!/bin/sh\nexec node \"\(fixture.path)\" \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "thread-context-\(UUID().uuidString)"
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
    try startT3ProtocolFixture(
      service: service, workspace: workspace, stateDirectory: state, binary: binary,
      model: "test/model")
    client.start(service: service)
    try await client.waitUntilReady()
    let environment = try await client.recoveryEnvironmentID()
    let source = UUID().uuidString
    let project = try await client.ensureProject(root)
    try await client.dispatch([
      "type": "thread.create", "threadId": source, "projectId": project, "title": "引用源",
      "modelSelection": ["instanceId": "pi", "model": "test/model"],
      "runtimeMode": "full-access", "interactionMode": "default",
      "branch": NSNull(), "worktreePath": NSNull(),
    ])
    let copied = try await T3ThreadContext.copy(
      environmentID: environment, threadID: source, title: "引用源")
    let pasted = try await T3ThreadContext.paste(copied, existing: nil, environmentID: environment)
    let text = pasted.text + "\n目前进度怎么样？"
    let store = MessageOutboxStore(directory: root.appendingPathComponent("outbox"))
    let record = try store.save(
      prompt: #require(
        AppModel.makePrompt(
          text, attachments: [], delivery: .followUp, messageContext: pasted.context)),
      messageID: UUID().uuidString, threadID: UUID().uuidString, project: root,
      selection: ["instanceId": "pi", "model": "test/model"], createsThread: true, context: "")
    let recovery = MessageRecoveryCoordinator(store: store, transport: client)
    #expect(await recovery.deliver(record.id))
    let commandData = try #require(store.message(record.id)?.dispatchCommand)
    let command = try #require(JSONSerialization.jsonObject(with: commandData) as? [String: Any])
    #expect(T3MessageContext.read(command["context"]) == pasted.context)
    var snapshot: [String: Any] = [:]
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      snapshot = try await client.recoverySnapshot(threadID: record.threadID)
      let projection = snapshot["projection"] as? [String: Any]
      if (projection?["runs"] as? [[String: Any]])?.contains(where: {
        $0["status"] as? String == "completed"
      }) == true {
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    let projection = try #require(snapshot["projection"] as? [String: Any])
    #expect(
      (projection["runs"] as? [[String: Any]])?.contains {
        $0["status"] as? String == "completed"
      } == true)
    let message = try #require(
      (projection["messages"] as? [[String: Any]])?.first {
        $0["id"] as? String == record.id
      })
    #expect(T3MessageContext.read(message["context"]) == pasted.context)
    let detail = T3V2Presentation.detail(snapshot)
    let model = AppModel(continueLastSession: false)
    model.currentSessionPath = "t3:\(record.threadID)"
    model.apply(detail)
    #expect(model.messages.first { $0.id == record.id }?.messageContext == pasted.context)
    let log = try String(
      contentsOf: root.appendingPathComponent("fixture-rpc.ndjson"), encoding: .utf8)
    let prompts = try log.split(separator: "\n").compactMap {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }.filter { $0["command"] as? String == "prompt" }
    let providerText = try #require(prompts.last?["message"] as? String)
    #expect(providerText.contains("threadId: \(source)"))
    #expect(providerText.contains("t3_thread_read"))
    #expect(!providerText.contains("unavailable=\"true\""))
  }
}

import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3GoalControlTests {
  @Test(.timeLimit(.minutes(2)))
  func stoppingParentPreservesRunningDelegatedChild() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/goal-clear-stop/server-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let binary = root.appendingPathComponent("fixture-pi")
    let fixture = repository.appendingPathComponent("sidecars/t3-server/tests/fixtures/pi.mjs")
    try "#!/bin/sh\nexec node \"\(fixture.path)\" \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "goal-control-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults, stateDirectory: root)
    let client = T3DesktopClient(defaults: defaults)
    let model = AppModel(startupProjectURL: root, continueLastSession: false)
    defer {
      model.disconnect()
      client.stop()
      service.stop()
      workspace.disconnectAll()
      defaults.removePersistentDomain(forName: suite)
    }
    try startT3ProtocolFixture(
      service: service, workspace: workspace, stateDirectory: root, binary: binary,
      model: "test/model")
    client.start(service: service)
    try await client.waitUntilReady()
    model.attach(to: client)
    model.selectedModelId = "test/model"
    model.composerText = "mcp-delegate-wait"
    model.sendPrompt()
    for _ in 0..<500 where model.threadID == nil || !model.isStreaming {
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(model.isStreaming)
    let parentID = try #require(model.threadID)
    var childID: String?
    for _ in 0..<300 where childID == nil {
      let detail = try await client.request("/api/orchestration/threads/\(parentID)")
      let projection = detail["projection"] as? [String: Any]
      childID = (projection?["subagents"] as? [[String: Any]])?.first?["childThreadId"] as? String
      if childID == nil { try await Task.sleep(for: .milliseconds(30)) }
    }
    let child = try #require(childID)
    func childIsRunning() async throws -> Bool {
      let encoded = try #require(
        child.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
      let detail = try await client.request("/api/orchestration/threads/\(encoded)")
      let projection = detail["projection"] as? [String: Any]
      return (projection?["runs"] as? [[String: Any]])?.contains {
        $0["status"] as? String == "running"
      } == true
    }
    for _ in 0..<300 {
      if try await childIsRunning() { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    try #require(try await childIsRunning())
    model.composerText = "保留草稿"
    model.abort()
    for _ in 0..<500 where model.isStreaming || model.isStopping || model.terminalStopReason == nil
    {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!model.isStreaming)
    #expect(model.terminalStopReason == "aborted")
    #expect(model.composerText == "保留草稿")
    // 等待原先的级联停止 effect 足以执行，避免仅在命令 ACK 的瞬间误判通过。
    try await Task.sleep(for: .milliseconds(500))
    #expect(try await childIsRunning())
    // 对照上游默认行为：不传 false 时确实会取消同一个子代理，证明夹具能捕获原故障。
    try await client.dispatch(["type": "thread.stop", "threadId": parentID])
    for _ in 0..<300 {
      if try await !childIsRunning() { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    #expect(try await !childIsRunning())
  }
}

import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct FastModeTests {
  @Test(.timeLimit(.minutes(1)))
  func fastSelectionSurvivesRefreshAndReachesPiWithoutChangingThinking() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/fast-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // 仅使用本地协议 fixture；不连接真实模型或读取用户账户。
    let fixture = try String(
      contentsOf: repository.appendingPathComponent(
        "sidecars/t3-server/tests/fixtures/pi.mjs"), encoding: .utf8
    )
    .replacingOccurrences(
      of: "provider: 'test', id: 'model', name: 'Test Model'",
      with:
        "provider: 'openai-codex', id: 'gpt-6.1-sol', api: 'openai-codex-responses', name: '6.1 Sol'"
    )
    try fixture.write(to: root.appendingPathComponent("pi.mjs"), atomically: true, encoding: .utf8)
    let binary = root.appendingPathComponent("pi")
    try "#!/bin/sh\nexec node '\(root.appendingPathComponent("pi.mjs").path)' \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "pimac-fast-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(binary.path, forKey: "piPath")
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults)
    let client = T3DesktopClient(defaults: defaults)
    let model = AppModel(restoreLastProjectOnLaunch: false)
    defer {
      model.disconnect()
      client.stop()
      service.stop()
      workspace.disconnectAll()
    }
    try startT3ProtocolFixture(
      service: service, workspace: workspace,
      stateDirectory: root.appendingPathComponent("state"), binary: binary,
      model: "openai-codex/gpt-6.1-sol")
    client.start(service: service)
    try await client.waitUntilReady()
    model.attach(to: client)
    model.connect(to: root)
    for _ in 0..<200 where model.threadID == nil || model.isLoadingConfiguration {
      try await Task.sleep(for: .milliseconds(25))
    }
    let id = try #require(model.threadID)
    #expect(model.supportsFastMode)
    #expect(!model.fastModeEnabled)
    model.changeThinkingLevel(to: "high")
    try await Task.sleep(for: .milliseconds(150))
    model.changeFastMode(to: true)
    func waitForOption(_ value: String) async throws {
      for _ in 0..<200 {
        let options = client.thread(id)?["modelSelection"] as? [String: Any]
        if (options?["options"] as? [[String: Any]])?.contains(where: {
          $0["id"] as? String == "fastMode" && $0["value"] as? String == value
        }) == true {
          return
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      Issue.record("Fast selection was not persisted: \(value)")
    }
    try await waitForOption("on")
    try await client.refresh()
    #expect(model.fastModeEnabled)
    #expect(model.selectedThinkingLevel == "high")
    let previousSettledTurn = model.lastSettledTurnID
    model.composerText = "Fast request"
    model.sendPrompt()
    for _ in 0..<200 {
      if FileManager.default.fileExists(
        atPath: root.appendingPathComponent("fixture-rpc.ndjson").path),
        try String(contentsOf: root.appendingPathComponent("fixture-rpc.ndjson"), encoding: .utf8)
          .contains("/pimac-fast on")
      {
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    // 扩展确认发生在真实 prompt 之前；isBusy 尚未投影时可能仍为 false。
    // 必须等本轮 settlement，而不是把启动前的空闲误当作执行完成。
    for _ in 0..<400 where model.lastSettledTurnID == previousSettledTurn || model.isBusy {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(model.lastSettledTurnID != previousSettledTurn)
    #expect(!model.isBusy)
    let records = try String(
      contentsOf: root.appendingPathComponent("fixture-rpc.ndjson"), encoding: .utf8)
    #expect(records.contains("/pimac-fast on"))
    model.changeFastMode(to: false)
    try await waitForOption("off")
    model.composerText = "Normal request"
    model.sendPrompt()
    for _ in 0..<200 {
      let updated = try String(
        contentsOf: root.appendingPathComponent("fixture-rpc.ndjson"), encoding: .utf8)
      if updated.contains("/pimac-fast off") { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    let updated = try String(
      contentsOf: root.appendingPathComponent("fixture-rpc.ndjson"), encoding: .utf8)
    #expect(updated.contains("/pimac-fast off"))
    #expect(model.selectedThinkingLevel == "high")
  }
}

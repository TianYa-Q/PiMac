import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3DesktopTests {
  @Test func cachedShellIsVisibleBeforeConnectionButCannotAuthorizeCommands() throws {
    let suite = "pimac-cache-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(try JSONSerialization.data(withJSONObject: [
      "projects": [["id": "project-1", "workspaceRoot": "/tmp/project"]],
      "threads": [["id": "thread-1", "projectId": "project-1"]],
    ]), forKey: "t3DesktopShellCache")
    let client = T3DesktopClient(defaults: defaults)
    #expect(client.projects.count == 1)
    #expect(client.thread("thread-1") != nil)
    #expect(!client.isConnected)
  }

  @Test func unchangedShellIsDeliveredOnlyOnceIncludingDiskCache() throws {
    let suite = "pimac-poll-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let snapshot: [String: Any] = ["threads": [["id": "thread-1", "title": "Before"]]]
    defaults.set(try JSONSerialization.data(withJSONObject: snapshot), forKey: "t3DesktopShellCache")
    let client = T3DesktopClient(defaults: defaults)
    var deliveries = 0
    client.onShell = { _ in deliveries += 1 }
    client.applyShell(snapshot)
    client.applyShell(snapshot)
    #expect(deliveries == 1)
    client.applyShell(["threads": [["id": "thread-1", "title": "After"]]])
    #expect(deliveries == 2)
    #expect(client.thread("thread-1")?["title"] as? String == "After")
    client.stop()
    client.applyShell(client.shell)
    #expect(deliveries == 3)
  }

  @Test func reusableDateParsersSupportBothTimestampFormats() {
    let seconds = T3DesktopClient.date("2026-10-03T00:00:00Z")
    let fractional = T3DesktopClient.date("2026-10-03T00:00:00.125Z")
    #expect(seconds != .distantPast)
    #expect(abs(fractional.timeIntervalSince(seconds) - 0.125) < 0.001)
    #expect(T3DesktopClient.date("invalid") == .distantPast)
    #expect(T3DesktopClient.date(nil) == .distantPast)
  }

  @Test func sessionOrderDoesNotChangeWhenConcurrentThreadsUpdate() {
    let older: [String: Any] = [
      "id": "older", "projectId": "project", "title": "Older",
      "createdAt": "2026-10-01T00:00:00Z", "updatedAt": "2026-10-03T00:00:00Z",
    ]
    let newer: [String: Any] = [
      "id": "newer", "projectId": "project", "title": "Newer",
      "createdAt": "2026-10-02T00:00:00Z", "updatedAt": "2026-10-02T00:00:00Z",
    ]
    let initial = WorkspaceModel.sessionCatalog(threads: [older, newer], projectID: "project")
    #expect(initial.map(\.path) == ["t3:newer", "t3:older"])
    var updated = older
    updated["updatedAt"] = "2026-10-04T00:00:00Z"
    updated["title"] = "Updated title"
    let refreshed = WorkspaceModel.sessionCatalog(threads: [newer, updated], projectID: "project")
    #expect(refreshed.map(\.path) == initial.map(\.path))
    #expect(refreshed.last?.title == "Updated title")
    #expect(refreshed.last!.modifiedAt > initial.last!.modifiedAt)
  }

  @Test func sessionCreationTiesHaveDeterministicOrder() {
    let threads: [[String: Any]] = [
      ["id": "b", "projectId": "project", "createdAt": "2026-10-02T00:00:00Z"],
      ["id": "a", "projectId": "project", "createdAt": "2026-10-02T00:00:00Z"],
      ["id": "other", "projectId": "other"],
    ]
    let expected = ["t3:a", "t3:b"]
    #expect(WorkspaceModel.sessionCatalog(threads: threads, projectID: "project").map(\.path) == expected)
    #expect(WorkspaceModel.sessionCatalog(threads: threads.reversed(), projectID: "project").map(\.path) == expected)
  }

  @Test func historicalPathsCannotBecomeRuntimeTargets() {
    #expect(AppModel.threadID(from: "/tmp/session.jsonl") == nil)
    #expect(AppModel.threadID(from: "t3:") == nil)
    #expect(AppModel.threadID(from: "t3:thread-1") == "thread-1")
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.connectionState = .connected
    #expect(!model.canSubmitPrompt)  // A UI flag cannot replace Server readiness.
    #expect(!model.supportsFastMode)
    #expect(!model.canManageAccounts)
  }

  @Test(.timeLimit(.minutes(1)))
  func desktopUsesNativeLoopbackServerWithTunnelOnlyPhoneAccess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = repository.appendingPathComponent("sidecars/t3-server/tests/fixtures/pi.mjs")
    let binary = root.appendingPathComponent("fixture-pi")
    try "#!/bin/sh\nexec node \"\(fixture.path)\" \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "pimac-desktop-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(binary.path, forKey: "piPath")
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(
      defaults: defaults, stateDirectory: root.appendingPathComponent("state"))
    let client = T3DesktopClient(defaults: defaults)
    defer {
      client.stop()
      service.stop()
      workspace.disconnectAll()
    }
    try service.start(
      workspace: workspace, token: T3NetworkEndpoint.secret(),
      stateDirectory: root.appendingPathComponent("state"))
    client.start(service: service)
    try await client.waitUntilReady()
    let model = AppModel(startupProjectURL: root, continueLastSession: false)
    defer { model.disconnect() }
    model.attach(to: client)
    for _ in 0..<200 where !model.canSubmitPrompt {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.canSubmitPrompt)
    #expect(model.currentSessionPath.hasPrefix("t3:"))
    #expect(model.thinkingLevels.contains("xhigh"))
    #expect(model.thinkingLevels.contains("max"))
    #expect(model.selectedThinkingLevel == model.globalDefaultThinkingLevel)
    model.changeThinkingLevel(to: "xhigh")
    for _ in 0..<200 where model.isBusy {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.selectedThinkingLevel == "xhigh")
    #expect(!model.isBusy)
    model.composerText = "tools"
    model.sendPrompt()
    for _ in 0..<200 where model.lastSettledTurnID == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.messages.contains { $0.kind == .user && $0.text == "tools" })
    let read = try #require(model.messages.first { $0.toolName == "read" })
    #expect(read.text == "done\nsecond line\nthird line")
    #expect(read.toolInput == "fixture.txt")
    #expect(!read.isRunning)
    let code = try #require(model.messages.first { $0.toolName == "codemode" })
    #expect(code.toolInput == "const value = 1;\ntext(value);")
    #expect(code.text == "Script completed\nOutput:\n1")
    #expect(code.nestedCalls.first?.input == "nested.txt")
    #expect(model.messages.contains { $0.kind == .assistant })
    #expect(model.lastSettledTurnID != nil)  // Also covers turns completed between polls.
    #expect(model.terminalStopReason == nil)
    model.refreshCodexAccounts()
    for _ in 0..<100 where model.stats == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.stats?.contextPercent == 2)
    #expect(model.stats?.totalTokens == 200)
    #expect(model.stats?.cost == 0.012)
    #expect(defaults.data(forKey: "t3DesktopShellCache") != nil)
    #expect(defaults.data(forKey: "t3DesktopMetrics.\(model.threadID!)") != nil)
    #expect((model.outputTokensPerSecond ?? 0) > 0)
    model.composerText = "slow"
    model.sendPrompt()
    for _ in 0..<100 where !model.isStreaming {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.isStreaming)
    model.composerText = "steer-now"
    model.sendPrompt(delivery: .steer)
    for _ in 0..<100 where !model.composerText.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.composerText.isEmpty)
    #expect(model.queuedPrompts.isEmpty)
    #expect(!model.awaitingAgentStart)
    #expect(model.isStreaming)
    model.composerText = "queued-followup"
    model.sendPrompt(delivery: .followUp)
    #expect(model.queuedPrompts.count == 1)
    #expect(model.composerText.isEmpty)
    #expect(!model.canRestartSafely)
    for _ in 0..<200 where !model.messages.contains(where: { $0.kind == .assistant && $0.text == "Reply: queued-followup" }) {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.queuedPrompts.isEmpty)
    #expect(model.messages.contains { $0.kind == .assistant && $0.text == "Reply: queued-followup" })
    let id = try #require(model.threadID)
    let detail = try await client.request("/api/orchestration/threads/\(id)")
    #expect((detail["thread"] as? [String: Any])?["id"] as? String == id)
    // Phone transport is Tunnel-only; the desktop retains its loopback Server.
    #expect(service.serverURL?.host == "127.0.0.1")
    let shell = try await client.request("/api/orchestration/shell")
    #expect((shell["threads"] as? [[String: Any]])?.contains { $0["id"] as? String == id } == true)
  }
}

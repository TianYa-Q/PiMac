import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct EmptyNewChatTests {
  private func emptyThread(
    _ id: String = "latest", project: String = "project", created: String = "2026-01-02T00:00:00Z"
  ) -> [String: Any] {
    [
      "id": id, "projectId": project, "title": "新任务", "createdAt": created,
      "status": "idle", "latestRunId": NSNull(), "latestVisibleMessage": NSNull(),
      "latestUserMessageAt": NSNull(), "activeRunId": NSNull(),
      "pendingRuntimeRequest": NSNull(),
    ]
  }

  @Test(.timeLimit(.minutes(1)))
  func createsThreadOnlyOnFirstSendForDesktopAndRemoteDrafts() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/empty-chat-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let binary = root.appendingPathComponent("pi")
    let fixture = repository.appendingPathComponent("sidecars/t3-server/tests/fixtures/pi.mjs")
    try "#!/bin/sh\nexec node '\(fixture.path)' \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "pimac-empty-chat-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(binary.path, forKey: "piPath")
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults)
    defer {
      workspace.disconnectAll()
      service.stop()
    }
    try startT3ProtocolFixture(
      service: service, workspace: workspace, stateDirectory: root.appendingPathComponent("state"),
      binary: binary, model: "test/model")
    workspace.server.start(service: service)
    try await workspace.server.waitUntilReady()
    workspace.newSession(in: root)
    let model = try #require(workspace.selectedModel)
    for _ in 0..<200 where model.isLoadingConfiguration {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(model.canSubmitPrompt)
    #expect(model.threadID == nil)
    workspace.newSession(in: root)
    #expect(workspace.selectedModel === model)
    model.composerText = " \n "
    model.sendPrompt()
    #expect(model.threadID == nil)
    model.composerText = "Unsent draft"
    workspace.newSession(in: root)
    let remoteDraft = try #require(workspace.selectedModel)
    #expect(remoteDraft !== model)
    for _ in 0..<200 where remoteDraft.isLoadingConfiguration {
      try await Task.sleep(for: .milliseconds(25))
    }
    try await workspace.server.refresh()
    #expect(workspace.server.threads.isEmpty)
    #expect(model.composerText == "Unsent draft")
    // 首次发送同步锁定提交；连续点击不能并发创建两个线程。
    model.sendPrompt()
    model.sendPrompt()
    for _ in 0..<400 where model.lastSettledTurnID == nil || model.isBusy {
      try await Task.sleep(for: .milliseconds(25))
    }
    let desktopID = try #require(model.threadID)
    #expect(model.lastSettledTurnID != nil)
    #expect(model.messages.filter { $0.kind == .user }.count == 1)
    #expect(model.composerText.isEmpty)
    try await workspace.server.refresh()
    #expect(workspace.server.threads.count == 1)
    var remoteResult: Bool?
    remoteDraft.sendRemotePrompt("Remote first message") { remoteResult = $0 }
    for _ in 0..<400 where remoteResult == nil || remoteDraft.isBusy {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(remoteResult == true)
    #expect(remoteDraft.threadID != nil)
    #expect(remoteDraft.threadID != desktopID)
    try await workspace.server.refresh()
    #expect(workspace.server.threads.count == 2)
  }

  @Test func reusesLatestEmptyThreadOnlyInRequestedProject() {
    let threads = [emptyThread(), emptyThread("other", project: "other")]
    #expect(
      WorkspaceModel.latestEmptySessionPath(threads: threads, projectID: "project") == "t3:latest")
    #expect(WorkspaceModel.latestEmptySessionPath(threads: threads, projectID: "missing") == nil)
  }

  @Test func doesNotReuseUsedRenamedRunningOrUnknownThread() {
    let mutations: [(String, Any)] = [
      ("title", "Custom task"), ("status", "running"), ("latestRunId", "run"),
      ("latestVisibleMessage", ["role": "user", "text": "hello"]),
      ("latestUserMessageAt", "2026-01-02T00:00:00Z"), ("activeRunId", "run"),
      ("pendingRuntimeRequest", ["id": "request"]),
    ]
    for (key, value) in mutations {
      var thread = emptyThread()
      thread[key] = value
      #expect(WorkspaceModel.latestEmptySessionPath(threads: [thread], projectID: "project") == nil)
    }
    var unknown = emptyThread()
    unknown.removeValue(forKey: "latestVisibleMessage")
    #expect(WorkspaceModel.latestEmptySessionPath(threads: [unknown], projectID: "project") == nil)
  }

  @Test func doesNotFallBackToOlderEmptyChat() {
    var used = emptyThread()
    used["latestRunId"] = "run"
    let older = emptyThread("older", created: "2026-01-01T00:00:00Z")
    #expect(
      WorkspaceModel.latestEmptySessionPath(threads: [older, used], projectID: "project") == nil)
  }

  @Test func repeatedClicksReusePendingDraftEvenFromAnotherProject() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let project = URL(fileURLWithPath: "/tmp/empty-chat-project")
    workspace.newSession(in: project)
    let draftID = workspace.selectedTabID
    workspace.newSession(in: project)
    #expect(workspace.tabs.count == 2)
    #expect(workspace.selectedTabID == draftID)
    workspace.newSession(in: URL(fileURLWithPath: "/tmp/another-project"))
    workspace.newSession(in: project)
    #expect(workspace.tabs.count == 3)
    #expect(workspace.selectedTabID == draftID)
  }

  @Test func doesNotDiscardComposerDraft() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let project = URL(fileURLWithPath: "/tmp/empty-chat-project")
    workspace.newSession(in: project)
    let previous = workspace.selectedModel
    previous?.composerText = "unsent text"
    workspace.newSession(in: project)
    #expect(workspace.tabs.count == 3)
    #expect(previous?.composerText == "unsent text")
  }
}

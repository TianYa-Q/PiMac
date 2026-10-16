import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct SessionTitleRegenerationTests {
  @Test func progressAndTitleFollowAuthoritativeShell() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    var thread: [String: Any] = [
      "id": "thread", "projectId": "project", "title": "原标题", "status": "running",
      "createdAt": "2026-10-16T00:00:00Z", "updatedAt": "2026-10-16T00:00:00Z",
    ]
    workspace.server.applyShell(["threads": [thread]])
    #expect(!workspace.isRegeneratingSessionTitle(threadID: "thread"))
    thread["titleRegeneration"] = [
      "requestId": "request", "startedAt": "2026-10-16T00:00:00Z",
    ]
    workspace.server.applyShell(["threads": [thread]])
    #expect(workspace.isRegeneratingSessionTitle(threadID: "thread"))
    #expect(workspace.restartBlockers.contains("会话标题重新生成中"))
    #expect(!workspace.isRegeneratingSessionTitle(threadID: "other"))
    #expect(workspace.server.sessions(projectID: "project").first?.title == "原标题")
    thread["title"] = "重新生成的标题"
    thread["titleRegeneration"] = NSNull()
    workspace.server.applyShell(["threads": [thread]])
    #expect(!workspace.isRegeneratingSessionTitle(threadID: "thread"))
    #expect(workspace.server.sessions(projectID: "project").first?.title == "重新生成的标题")
    #expect(!workspace.restartBlockers.contains("会话标题重新生成中"))
  }

  @Test(.timeLimit(.minutes(1)))
  func emptyConversationRegenerationUsesServerAndClearsProgress() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/title-regeneration-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "title-regeneration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults)
    defer {
      workspace.disconnectAll()
      service.stop()
    }
    // 隔离 Server 和凭据；空会话无需调用模型，也应正常清除生成意图并保留原标题。
    try startT3ProtocolFixture(
      service: service, workspace: workspace, stateDirectory: root, binary: nil,
      model: "test/model")
    workspace.server.start(service: service)
    try await workspace.server.waitUntilReady()
    #expect(workspace.server.supportsTitleRegeneration)
    let projectID = try await workspace.server.ensureProject(root)
    let threadID = UUID().uuidString
    try await workspace.server.dispatch(
      [
        "type": "thread.create", "threadId": threadID, "projectId": projectID,
        "title": "空会话原始标题", "modelSelection": ["instanceId": "pi", "model": "test/model"],
        "runtimeMode": "full-access", "interactionMode": "default",
        "branch": NSNull(), "worktreePath": NSNull(),
      ], refreshAfter: false)
    try await workspace.server.refreshShell()
    let previousUpdate = workspace.server.thread(threadID)?["updatedAt"] as? String
    await workspace.regenerateSessionTitle(path: "t3:\(threadID)")
    #expect(workspace.submittingTitleRegenerations.isEmpty)
    #expect(workspace.selectedModel?.statusText.contains("重新生成标题未确认") == false)
    for _ in 0..<40 where workspace.isRegeneratingSessionTitle(threadID: threadID) {
      try await Task.sleep(for: .milliseconds(100))
      try await workspace.server.refreshShell()
    }
    let thread = try #require(workspace.server.thread(threadID))
    #expect(thread["title"] as? String == "空会话原始标题")
    #expect(!workspace.isRegeneratingSessionTitle(threadID: threadID))
    // 生成意图的提交/清除都应写回 Server，而不是客户端静默跳过。
    #expect(thread["updatedAt"] as? String != previousUpdate)
    #expect(await service.stopAndWait())
  }
}

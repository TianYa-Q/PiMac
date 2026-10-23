import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ProjectLifecycleTests {
  @Test func completedLegacyImportDoesNotResurrectRemovedProjects() throws {
    let suite = "project-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("/tmp/last", forKey: "lastProjectPath")
    #expect(WorkspaceModel.legacyProjectPaths(defaults: defaults) == ["/tmp/last"])
    defaults.set(["/tmp/one", "/tmp/two"], forKey: "workspaceProjectPaths")
    #expect(WorkspaceModel.legacyProjectPaths(defaults: defaults) == ["/tmp/one", "/tmp/two"])
    defaults.set(true, forKey: "t3ProjectImportCompleted")
    #expect(WorkspaceModel.legacyProjectPaths(defaults: defaults).isEmpty)
  }

  @Test func addingAFileReportsInvalidDirectory() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    workspace.addProject(URL(fileURLWithPath: #filePath))
    #expect(workspace.selectedModel?.statusText == "添加项目失败：请选择存在的文件夹。")
    #expect(workspace.projects.isEmpty)
  }

  @Test func externalProjectRemovalClosesItsDraftAndClearsFilter() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let project = WorkspaceProject(url: URL(fileURLWithPath: "/tmp/project-removal"))
    workspace.server.applyShell([
      "projects": [["id": "p", "workspaceRoot": project.id, "title": "Project"]],
      "threads": [],
    ])
    workspace.newSession(in: project.url)
    workspace.selectedModel?.composerText = "saved draft"
    workspace.toggleProjectFilter(project)
    workspace.server.applyShell(["projects": [], "threads": []])
    #expect(workspace.projects.isEmpty)
    #expect(workspace.projectFilterPath == nil)
    #expect(!workspace.tabs.contains { $0.model.projectURL == project.url })
    #expect(workspace.selectedModel?.projectURL == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func serverConfirmsConcurrentAddArchiveWithoutProjectAndReaddAfterDelete() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/project-lifecycle-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "project-lifecycle-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults)
    defer { workspace.disconnectAll(); service.stop() }
    try startT3ProtocolFixture(
      service: service, workspace: workspace, stateDirectory: root, binary: nil,
      model: "test/model")
    let client = workspace.server
    client.start(service: service)
    try await client.waitUntilReady()
    async let first = client.ensureProject(root)
    async let concurrent = client.ensureProject(root.appendingPathComponent("."))
    let (id, duplicateID) = try await (first, concurrent)
    #expect(id == duplicateID)
    #expect(client.projects.count == 1)
    let threadID = UUID().uuidString
    try await client.dispatch([
      "type": "thread.create", "threadId": threadID, "projectId": id,
      "title": "归档回归", "modelSelection": ["instanceId": "pi", "model": "test/model"],
      "runtimeMode": "full-access", "interactionMode": "default",
      "branch": NSNull(), "worktreePath": NSNull(),
    ], refreshAfter: false)
    try await client.refreshShell()
    // 模拟旧客户端遗留的无项目列表：归档必须直接使用线程 ID，而不是依赖目录查找。
    client.applyShell(["projects": [], "threads": client.threads])
    #expect(workspace.project(forSessionPath: "t3:\(threadID)") == nil)
    workspace.archiveSession(path: "t3:\(threadID)")
    for _ in 0..<80 where client.thread(threadID) != nil {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(client.thread(threadID) == nil)
    try await client.refreshShell()
    let activeID = UUID().uuidString
    try await client.dispatch([
      "type": "thread.create", "threadId": activeID, "projectId": id,
      "title": "随项目移除", "modelSelection": ["instanceId": "pi", "model": "test/model"],
      "runtimeMode": "full-access", "interactionMode": "default",
      "branch": NSNull(), "worktreePath": NSNull(),
    ], refreshAfter: false)
    try await client.refreshShell()
    workspace.toggleProjectFilter(WorkspaceProject(url: root))
    workspace.removeProject(WorkspaceProject(url: root))
    for _ in 0..<80 where client.projectID(for: root) != nil {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(client.projectID(for: root) == nil)
    #expect(client.thread(activeID) == nil)
    #expect(workspace.filteredSessions.isEmpty)
    #expect(workspace.projectFilterPath == nil)
    let recreated = try await client.ensureProject(root)
    #expect(recreated != id)
    #expect(client.projectID(for: root) == recreated)
    #expect(client.projects.count == 1)
    #expect(await service.stopAndWait())
  }
}

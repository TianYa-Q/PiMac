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

}

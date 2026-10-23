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
    #expect(workspace.tabs.count == 2)
    #expect(workspace.selectedModel === previous)
    #expect(previous?.composerText == "unsent text")
  }
}

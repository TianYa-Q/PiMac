import Foundation
import Testing
@testable import PiMacApp

@MainActor
struct ProjectSessionFilterTests {
  @Test func filterIsIndependentOfActiveConversationAndCanBeCleared() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let selected = workspace.selectedTabID
    let first = WorkspaceProject(url: URL(fileURLWithPath: "/tmp/filter-first"))
    let second = WorkspaceProject(url: URL(fileURLWithPath: "/tmp/filter-second"))
    workspace.selectedModel?.composerText = "keep draft"
    workspace.toggleProjectFilter(first)
    #expect(workspace.projectFilterPath == first.id)
    workspace.toggleProjectFilter(second)
    #expect(workspace.projectFilterPath == second.id)
    workspace.toggleProjectFilter(second)
    #expect(workspace.projectFilterPath == nil)
    #expect(workspace.selectedTabID == selected)
    #expect(workspace.selectedModel?.composerText == "keep draft")
    workspace.toggleProjectFilter(first)
    workspace.clearProjectFilter()
    #expect(workspace.projectFilterPath == nil)
  }

  @Test func switchingNewChatTargetKeepsInputAndDoesNotChangeFilter() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let first = WorkspaceProject(url: URL(fileURLWithPath: "/tmp/filter-first"))
    let second = WorkspaceProject(url: URL(fileURLWithPath: "/tmp/filter-second"))
    let previous = workspace.selectedModel
    previous?.composerText = "send to second"
    workspace.toggleProjectFilter(first)
    workspace.switchNewChatProject(to: second)
    #expect(workspace.selectedModel?.projectURL == second.url)
    #expect(workspace.selectedModel?.composerText == "send to second")
    #expect(previous?.composerText == "")
    #expect(workspace.projectFilterPath == first.id)
  }

  @Test func allProjectsCatalogAndRowOwnership() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let first = WorkspaceProject(url: URL(fileURLWithPath: "/tmp/filter-first"))
    workspace.server.applyShell([
      "projects": [
        ["id": "one", "workspaceRoot": first.id, "title": "First"],
        ["id": "two", "workspaceRoot": "/tmp/filter-second", "title": "Second"],
      ],
      "threads": [
        ["id": "a", "projectId": "one", "title": "A", "createdAt": "2026-01-01T00:00:00Z"],
        ["id": "b", "projectId": "two", "title": "B", "createdAt": "2026-01-02T00:00:00Z"],
      ],
    ])
    #expect(workspace.filteredSessions.map(\.path) == ["t3:b", "t3:a"])
    #expect(workspace.project(forSessionPath: "t3:b")?.name == "Second")
    #expect(workspace.project(forSessionPath: "t3:b")?.id == "/tmp/filter-second")
    #expect(workspace.project(forSessionPath: "t3:missing") == nil)
    workspace.toggleProjectFilter(first)
    #expect(workspace.filteredSessions.map(\.path) == ["t3:a"])
    workspace.clearProjectFilter()
    #expect(workspace.filteredSessions.count == 2)
    workspace.toggleProjectFilter(WorkspaceProject(url: URL(fileURLWithPath: "/tmp/missing")))
    #expect(workspace.filteredSessions.isEmpty)
  }
}

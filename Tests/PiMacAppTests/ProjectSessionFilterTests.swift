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

  @Test func filtersFollowShellMovesSettlementAndProjectRemoval() {
    let defaults = UserDefaults(suiteName: "ProjectSessionFilterTests.\(UUID().uuidString)")!
    let workspace = WorkspaceModel(
      restoreUserState: false, server: T3DesktopClient(defaults: defaults))
    defer { workspace.disconnectAll() }
    let first = WorkspaceProject(url: URL(fileURLWithPath: "/tmp/filter-first"))
    var projects: [[String: Any]] = [
      ["id": "one", "workspaceRoot": first.id, "title": "First"],
      ["id": "two", "workspaceRoot": "/tmp/filter-second", "title": "Second"],
    ]
    var threads: [[String: Any]] = [
      ["id": "a", "projectId": "one", "createdAt": "2026-01-01T00:00:00Z"],
      ["id": "b", "projectId": "two", "createdAt": "2026-02-01T00:00:00Z"],
      [
        "id": "c", "projectId": "one", "activeOrderKey": "a",
        "settledOverride": "settled",
      ],
    ]
    workspace.server.applyShell(["projects": projects, "threads": threads])
    #expect(workspace.filteredSessions.map(\.path) == ["t3:b", "t3:a"])
    #expect(workspace.filteredSessions(settled: true).map(\.path) == ["t3:c"])
    #expect(workspace.server.sessions(projectID: "one").map(\.path) == ["t3:a", "t3:c"])
    workspace.toggleProjectFilter(first)
    #expect(workspace.filteredSessions.map(\.path) == ["t3:a"])
    #expect(workspace.filteredSessions(settled: true).map(\.path) == ["t3:c"])

    threads[0]["projectId"] = "two"
    threads[1]["projectId"] = "one"
    threads[1]["settledAt"] = "2026-03-01T00:00:00Z"
    threads[2].removeValue(forKey: "settledOverride")
    threads[2]["activeOrderKey"] = NSNull()
    threads[2]["unsettledAt"] = "2026-04-01T00:00:00Z"
    workspace.server.applyShell(["projects": projects, "threads": threads])
    #expect(workspace.filteredSessions.map(\.path) == ["t3:c"])
    #expect(workspace.filteredSessions(settled: true).map(\.path) == ["t3:b"])
    workspace.clearProjectFilter()
    #expect(workspace.filteredSessions.map(\.path) == ["t3:c", "t3:a"])
    workspace.toggleProjectFilter(first)
    projects.removeFirst()
    workspace.server.applyShell(["projects": projects, "threads": threads])
    #expect(workspace.projectFilterPath == nil)
    #expect(workspace.filteredSessions.map(\.path) == ["t3:c", "t3:a"])
    #expect(workspace.filteredSessions(settled: true).map(\.path) == ["t3:b"])
    workspace.server.applyShell(["projects": projects, "threads": []])
    #expect(workspace.filteredSessions.isEmpty)
    #expect(workspace.filteredSessions(settled: true).isEmpty)
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

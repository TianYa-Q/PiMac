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

}

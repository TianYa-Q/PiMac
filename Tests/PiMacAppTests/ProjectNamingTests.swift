import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ProjectNamingTests {
  @Test func customNameDoesNotChangeIdentityOrDirectory() {
    let url = URL(fileURLWithPath: "/tmp/PiMac")
    let original = WorkspaceProject(url: url)
    let renamed = WorkspaceProject(url: url, customName: "  我的项目 \n")
    #expect(renamed.name == "我的项目")
    #expect(renamed.id == original.id)
    #expect(renamed.url == original.url)
    #expect(original.name == "PiMac")
  }

  @Test func missingOrBlankTitleUsesDirectoryName() {
    let url = URL(fileURLWithPath: "/tmp/PiMac")
    for title: String? in [nil, "", " \n\t"] {
      #expect(WorkspaceProject(url: url, customName: title).name == "PiMac")
    }
  }

  @Test func projectMutationsUseOfficialProjectAPI() {
    for type in ["project.create", "project.update", "project.delete"] {
      #expect(T3DesktopClient.mutationMethod(for: type) == "projects.mutate")
    }
    #expect(T3DesktopClient.mutationMethod(for: "thread.create") == "orchestration.dispatchCommand")
  }
}

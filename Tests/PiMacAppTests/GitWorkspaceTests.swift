import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct GitWorkspaceTests {
  @Test func selectedFilePayloadsNeverCommitTheWholeWorkspaceImplicitly() {
    #expect(
      GitWorkspaceStore.actionPayload(cwd: "/repo", action: "commit", message: "hi", files: [])
        == nil)
    #expect(
      GitWorkspaceStore.actionPayload(cwd: "/repo", action: "commit", message: "  ", files: ["a"])
        == nil)
    #expect(
      GitWorkspaceStore.actionPayload(cwd: "/repo", action: "unknown", message: "hi", files: ["a"])
        == nil)
    let payload = GitWorkspaceStore.actionPayload(
      cwd: "/repo", action: "commit_push", message: " fix ", files: ["b", "a"])
    #expect(payload?["filePaths"] as? [String] == ["a", "b"])
    #expect(payload?["commitMessage"] as? String == "fix")
    #expect(payload?["actionId"] is String)
    let push = GitWorkspaceStore.actionPayload(cwd: "/repo", action: "push", message: "", files: [])
    #expect(push != nil)
    #expect(push?["filePaths"] == nil)
  }

  @Test func statusRetainsDetachedHeadAndServerFileCounts() {
    let status = GitWorkspaceStatus([
      "isRepo": true, "refName": NSNull(), "hasUpstream": true,
      "aheadCount": 2, "behindCount": 1,
      "workingTree": ["files": [["path": "a.swift", "insertions": 3, "deletions": 4]]],
    ])
    #expect(status.isRepo)
    #expect(status.branch == nil)
    #expect(status.ahead == 2 && status.behind == 1)
    #expect(status.files.first?.insertions == 3)
    #expect(status.files.first?.deletions == 4)
  }

}

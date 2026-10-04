import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct GitOperationSafetyTests {
  private func snapshot(_ branch: String = "main") -> [String: Any] {
    [
      "isRepo": true, "refName": branch, "hasUpstream": false,
      "aheadCount": 0, "behindCount": 0,
      "workingTree": ["files": [["path": "a.swift", "insertions": 1, "deletions": 0]]],
    ]
  }

  private func readyStore() async -> GitWorkspaceStore {
    let store = GitWorkspaceStore()
    await store.refresh(cwd: "/repo") { method, _ in
      method == "vcs.listRefs" ? ["refs": []] : snapshot()
    }
    return store
  }

  @Test func commitRejectsUnsafeRelativePaths() {
    for path in ["", "/tmp/file", "../file", "a/../file", "./file", "a//file", "a/", "a\0b"] {
      #expect(
        GitWorkspaceStore.actionPayload(
          cwd: "/repo", action: "commit", message: "fix", files: [path]) == nil,
        "\(path)")
    }
    for path in ["a.swift", "-option", "目录/说明.md", "a b", "a\nb"] {
      #expect(
        GitWorkspaceStore.actionPayload(
          cwd: "/repo", action: "commit", message: "fix", files: [path]) != nil)
    }
  }

  @Test func refreshedSnapshotExpiresConfirmationWithoutSending() async throws {
    let store = await readyStore()
    let original = store.snapshotID
    await store.refresh(cwd: "/repo") { method, _ in
      method == "vcs.listRefs" ? ["refs": []] : snapshot("other")
    }
    let payload = try #require(
      GitWorkspaceStore.actionPayload(cwd: "/repo", action: "push", message: "", files: []))
    var calls = 0
    let completed = await store.perform(
      method: "git.runStackedAction", payload: payload, cwd: "/repo", expectedSnapshotID: original
    ) { _, _ in
      calls += 1
      return [:]
    }
    #expect(!completed && calls == 0)
    #expect(store.message.contains("操作未发送"))
    #expect(!store.requiresRefresh && store.status?.branch == "other")
  }

  @Test func missingFilesAndUnknownMethodsNeverReachTransport() async throws {
    let store = await readyStore()
    let payload = try #require(
      GitWorkspaceStore.actionPayload(
        cwd: "/repo", action: "commit", message: "fix", files: ["missing"]))
    var calls = 0
    for method in ["git.runStackedAction", "vcs.deleteRef"] {
      let completed = await store.perform(
        method: method, payload: payload, cwd: "/repo", expectedSnapshotID: store.snapshotID
      ) { _, _ in
        calls += 1
        return [:]
      }
      #expect(!completed)
    }
    #expect(calls == 0 && !store.busy)
  }

  @Test func failedMutationRequiresExplicitRefreshAndIsNeverReplayed() async throws {
    let store = await readyStore()
    let payload = try #require(
      GitWorkspaceStore.actionPayload(
        cwd: "/repo", action: "commit", message: "fix", files: ["a.swift"]))
    var calls = 0
    let completed = await store.perform(
      method: "git.runStackedAction", payload: payload, cwd: "/repo",
      expectedSnapshotID: store.snapshotID
    ) { _, _ in
      calls += 1
      throw URLError(.timedOut)
    }
    #expect(!completed && store.requiresRefresh && !store.busy && store.progress.isEmpty)
    await store.perform(
      method: "git.runStackedAction", payload: payload, cwd: "/repo",
      expectedSnapshotID: store.snapshotID
    ) { _, _ in
      calls += 1
      return [:]
    }
    #expect(calls == 1)
  }

  @Test func confirmedMutationRefreshesAndDropsRemovedSelections() async throws {
    let store = await readyStore()
    store.selectedFiles = ["a.swift"]
    let payload = try #require(
      GitWorkspaceStore.actionPayload(
        cwd: "/repo", action: "commit", message: "fix", files: ["a.swift"]))
    var calls: [String] = []
    let completed = await store.perform(
      method: "git.runStackedAction", payload: payload, cwd: "/repo",
      expectedSnapshotID: store.snapshotID
    ) { method, _ in
      calls.append(method)
      if method == "vcs.refreshStatus" {
        var clean = snapshot()
        clean["workingTree"] = ["files": []]
        return clean
      }
      return method == "vcs.listRefs" ? ["refs": []] : [:]
    }
    #expect(completed && !store.busy && !store.requiresRefresh)
    #expect(store.selectedFiles.isEmpty)
    #expect(calls == ["git.runStackedAction", "vcs.refreshStatus", "vcs.listRefs"])
  }

  @Test func reconciliationHoldsLeaseUntilFreshStateIsLoaded() async throws {
    let store = await readyStore()
    let payload = try #require(
      GitWorkspaceStore.actionPayload(cwd: "/repo", action: "push", message: "", files: []))
    var interleavedCalls = 0
    let completed = await store.perform(
      method: "git.runStackedAction", payload: payload, cwd: "/repo",
      expectedSnapshotID: store.snapshotID
    ) { method, _ in
      if method == "vcs.refreshStatus" {
        #expect(store.busy && store.loading)
        await store.refresh(cwd: "/other") { _, _ in
          interleavedCalls += 1
          return ["isRepo": false]
        }
        await store.perform(
          method: "git.runStackedAction", payload: payload, cwd: "/repo",
          expectedSnapshotID: store.snapshotID
        ) { _, _ in
          interleavedCalls += 1
          return [:]
        }
        return snapshot()
      }
      return method == "vcs.listRefs" ? ["refs": []] : [:]
    }
    #expect(completed && !store.busy && interleavedCalls == 0)
    #expect(store.status?.branch == "main")
  }

  @Test func branchSearchPrioritizesCurrentAndCombinesTerms() {
    let branches = ["feature/ui-10", "main", "feature/ui-2", "feature/api", "main"]
    #expect(
      GitWorkspacePresentation.filteredBranches(branches, query: "FEATURE ui", current: "main") == [
        "feature/ui-2", "feature/ui-10",
      ])
    #expect(
      GitWorkspacePresentation.filteredBranches(branches, query: "", current: "feature/ui-10").first
        == "feature/ui-10")
    #expect(
      GitWorkspacePresentation.filteredBranches(branches, query: "missing", current: "main").isEmpty
    )
  }
}

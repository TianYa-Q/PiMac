import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct GitWorkspacePresentationTests {
  private let files = [
    GitWorkspaceStatus.File(path: "Sources/App/Main.swift", insertions: 1, deletions: 0),
    GitWorkspaceStatus.File(path: "Tests/MainTests.swift", insertions: 0, deletions: 2),
    GitWorkspaceStatus.File(path: "docs/说明.md", insertions: 1, deletions: 1),
  ]

  @Test func searchCombinesTermsAndKeepsOriginalOrder() {
    #expect(
      GitWorkspacePresentation.filteredFiles(files, query: " SWIFT main ").map(\.path)
        == Array(files.prefix(2)).map(\.path))
    #expect(
      GitWorkspacePresentation.filteredFiles(files, query: "sources swift").map(\.path) == [
        files[0].path
      ])
    #expect(GitWorkspacePresentation.filteredFiles(files, query: "说明").count == 1)
    #expect(GitWorkspacePresentation.filteredFiles(files, query: "  \n") == files)
    #expect(GitWorkspacePresentation.filteredFiles(files, query: "missing").isEmpty)
  }

  @Test func selectedChangeTotalsIgnoreHiddenAndSaturateOverflow() {
    let totals = GitWorkspacePresentation.selectedChanges(files, selected: [files[1].path])
    #expect(totals.insertions == 0 && totals.deletions == 2)
    let huge = [
      GitWorkspaceStatus.File(path: "a", insertions: Int.max, deletions: 0),
      GitWorkspaceStatus.File(path: "b", insertions: 1, deletions: -1),
    ]
    let saturated = GitWorkspacePresentation.selectedChanges(huge, selected: ["a", "b"])
    #expect(saturated.insertions == Int.max && saturated.deletions == 0)
  }

  @Test func visibleSelectionNeverDropsHiddenFiles() {
    let hidden: Set<String> = [files[2].path]
    let selected = GitWorkspacePresentation.toggledSelection(
      hidden, visible: Array(files.prefix(2)))
    #expect(selected == Set(files.map(\.path)))
    #expect(
      GitWorkspacePresentation.toggledSelection(selected, visible: Array(files.prefix(2))) == hidden
    )
    #expect(GitWorkspacePresentation.toggledSelection(hidden, visible: []) == hidden)
  }

  @Test func validatesBranchNamesBeforeSendingToServer() {
    for name in ["feature/ui", "修复/连接", " release-1.2 ", "a@b", "a.locked"] {
      #expect(GitWorkspacePresentation.branchNameError(name) == nil, "\(name)")
    }
    for name in [
      "", " ", "@", "-option", "a..b", "a@{b", "a b", "a\tb", "a\u{7f}b", "a~b", "a^b", "a:b",
      "a?b", "a*b", "a[b", "a\\b", "/a", "a/", "a//b", ".a", "a/.b", "a.lock", "a.lock/b", "a.",
    ] {
      #expect(GitWorkspacePresentation.branchNameError(name) != nil, "\(name)")
    }
  }

  @Test func statusDeduplicatesIdentityAndDropsEmptyPaths() {
    let status = GitWorkspaceStatus([
      "isRepo": true,
      "workingTree": [
        "files": [
          ["path": "a", "insertions": 2], ["path": "a", "insertions": 9], ["path": ""], [:],
        ]
      ],
    ])
    #expect(status.files.count == 1)
    #expect(status.files.first?.insertions == 2)
  }

  @Test func nonRepositoryDoesNotRequestRefs() async {
    let store = GitWorkspaceStore()
    var methods: [String] = []
    await store.refresh(cwd: "/empty") { method, _ in
      methods.append(method)
      return ["isRepo": false]
    }
    #expect(methods == ["vcs.refreshStatus"])
    #expect(store.status?.isRepo == false)
    #expect(!store.requiresRefresh && !store.loading)
  }

  private func snapshot(_ branch: String) -> [String: Any] {
    [
      "isRepo": true, "refName": branch, "hasUpstream": false,
      "aheadCount": 0, "behindCount": 0, "workingTree": ["files": []],
    ]
  }

  @Test func selectedScopeCombinesWithSearch() {
    #expect(
      GitWorkspacePresentation.filteredFiles(
        files, query: "swift", scope: .selected, selected: [files[1].path, files[2].path]
      ).map(\.path) == [files[1].path])
    #expect(GitWorkspacePresentation.filteredFiles(files, query: "", scope: .selected).isEmpty)
  }

  @Test func unselectedScopeAndSortPreserveSelectionAndHandleOverflow() {
    #expect(
      GitWorkspacePresentation.filteredFiles(
        files, query: "swift", scope: .unselected, selected: [files[0].path]
      ).map(\.path) == [files[1].path])
    let sorted = GitWorkspacePresentation.filteredFiles(files, query: "", sort: .changes)
    #expect(sorted.map(\.path) == [files[2].path, files[1].path, files[0].path])
    let huge = [
      GitWorkspaceStatus.File(path: "b", insertions: Int.max, deletions: 1),
      GitWorkspaceStatus.File(path: "a", insertions: Int.max, deletions: 2),
      GitWorkspaceStatus.File(path: "z", insertions: 1, deletions: 0),
    ]
    #expect(
      GitWorkspacePresentation.filteredFiles(huge, query: "", sort: .changes).map(\.path)
        == ["a", "b", "z"])
    #expect(
      GitWorkspacePresentation.filteredFiles(huge, query: "", sort: .path).map(\.path)
        == ["a", "b", "z"])
  }

  @Test func malformedSnapshotsNeverUnlockActionsOrReplaceKnownState() async {
    let store = GitWorkspaceStore()
    await store.refresh(cwd: "/repo") { method, _ in
      method == "vcs.listRefs" ? ["refs": []] : snapshot("main")
    }
    let refreshedAt = store.refreshedAt
    #expect(refreshedAt != nil)
    var duplicate = snapshot("other")
    duplicate["workingTree"] = [
      "files": [
        ["path": "a", "insertions": 0, "deletions": 0],
        ["path": "a", "insertions": 0, "deletions": 0],
      ]
    ]
    var booleanCount = snapshot("other")
    booleanCount["aheadCount"] = true
    for invalid in [[:], ["isRepo": true], duplicate, booleanCount] {
      await store.refresh(cwd: "/repo") { _, _ in invalid }
      #expect(store.requiresRefresh && !store.loading)
      #expect(store.status?.branch == "main")
      #expect(store.refreshedAt == refreshedAt)
    }
    await store.refresh(cwd: "/repo") { method, _ in
      method == "vcs.listRefs" ? [:] : snapshot("other")
    }
    #expect(store.requiresRefresh && store.status?.branch == "main")
  }

  @Test func newerWorkspaceWinsEvenWhenOlderRefreshFinishesLast() async {
    let store = GitWorkspaceStore()
    var oldRefsRequested = false
    await store.refresh(cwd: "/old") { method, _ in
      if method == "vcs.listRefs" { oldRefsRequested = true }
      await store.refresh(cwd: "/new") { method, _ in
        if method == "vcs.listRefs" {
          return ["refs": [["name": "new"], ["name": "new"], ["name": "alpha"]]]
        }
        return snapshot("new")
      }
      return snapshot("old")
    }
    #expect(store.status?.branch == "new")
    #expect(store.branches == ["alpha", "new"])
    #expect(!store.loading && !store.requiresRefresh)
    #expect(!oldRefsRequested)
  }

  @Test func cancelledRefreshLocksActionsUntilSuccessfulRefresh() async {
    let store = GitWorkspaceStore()
    await store.refresh(cwd: "/repo") { method, _ in
      method == "vcs.listRefs" ? ["refs": []] : snapshot("main")
    }
    await store.refresh(cwd: "/repo") { _, _ in throw CancellationError() }
    #expect(store.requiresRefresh && !store.loading)
    #expect(store.status?.branch == "main")
    await store.refresh(cwd: "/repo") { method, _ in
      method == "vcs.listRefs" ? ["refs": []] : snapshot("main")
    }
    #expect(!store.requiresRefresh)
  }
}

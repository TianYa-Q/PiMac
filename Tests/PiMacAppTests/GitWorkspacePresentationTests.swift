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

  @Test func newerWorkspaceWinsEvenWhenOlderRefreshFinishesLast() async {
    let store = GitWorkspaceStore()
    var oldRefsRequested = false
    await store.refresh(cwd: "/old") { method, _ in
      if method == "vcs.listRefs" { oldRefsRequested = true }
      await store.refresh(cwd: "/new") { method, _ in
        if method == "vcs.listRefs" {
          return ["refs": [["name": "new"], ["name": "new"], ["name": "alpha"]]]
        }
        return ["isRepo": true, "refName": "new"]
      }
      return ["isRepo": true, "refName": "old"]
    }
    #expect(store.status?.branch == "new")
    #expect(store.branches == ["alpha", "new"])
    #expect(!store.loading && !store.requiresRefresh)
    #expect(!oldRefsRequested)
  }

  @Test func cancelledRefreshLocksActionsUntilSuccessfulRefresh() async {
    let store = GitWorkspaceStore()
    await store.refresh(cwd: "/repo") { method, _ in
      method == "vcs.listRefs" ? ["refs": []] : ["isRepo": true, "refName": "main"]
    }
    await store.refresh(cwd: "/repo") { _, _ in throw CancellationError() }
    #expect(store.requiresRefresh && !store.loading)
    #expect(store.status?.branch == "main")
    await store.refresh(cwd: "/repo") { method, _ in
      method == "vcs.listRefs" ? ["refs": []] : ["isRepo": true, "refName": "main"]
    }
    #expect(!store.requiresRefresh)
  }
}

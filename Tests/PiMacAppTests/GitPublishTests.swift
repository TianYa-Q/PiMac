import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct GitPublishTests {
  private func snapshot(files: Bool, ahead: Int, upstream: Bool) -> [String: Any] {
    [
      "isRepo": true, "refName": "main", "hasUpstream": upstream,
      "aheadCount": ahead, "behindCount": 0,
      "workingTree": [
        "files": files ? [["path": "a.swift", "insertions": 1, "deletions": 0]] : []
      ],
    ]
  }

  private let context = GitWorkspaceContext(cwd: "/repo", threadID: "t", projectID: "p")
  private var result: [String: Any] {
    [
      "action": "commit_push", "commit": ["status": "created"],
      "push": ["status": "pushed"],
    ]
  }

  @Test func delegatesWholeWorkspaceAndGenerationToServerWithLease() async {
    let store = GitWorkspaceStore()
    var calls: [String] = []
    var sent = false
    let completed = await store.publish(context: context) { method, payload in
      #expect(store.busy)
      calls.append(method)
      if method == "git.runStackedAction" {
        sent = true
        #expect(payload["cwd"] as? String == "/repo")
        #expect(payload["action"] as? String == "commit_push")
        #expect(payload["threadId"] as? String == "t")
        #expect(payload["projectId"] as? String == "p")
        #expect(payload["actionId"] as? String != nil)
        #expect(payload["commitMessage"] == nil && payload["filePaths"] == nil)
        // 嵌套点击和跨工作区刷新都不得越过同一把操作锁。
        let duplicate = await store.publish(context: context) { _, _ in
          Issue.record("重复操作不应到达传输层")
          return [:]
        }
        #expect(!duplicate)
        await store.refresh(cwd: "/other") { _, _ in
          Issue.record("流程结束前不能切换快照工作区")
          return [:]
        }
        return result
      }
      return method == "vcs.listRefs"
        ? ["refs": []] : snapshot(files: !sent, ahead: 0, upstream: true)
    }
    #expect(completed && !store.busy && !store.requiresRefresh)
    #expect(store.message == "已提交并推送。" && store.progress.isEmpty)
    #expect(
      calls == [
        "vcs.refreshStatus", "vcs.listRefs", "git.runStackedAction",
        "vcs.refreshStatus", "vcs.listRefs",
      ])
  }

  @Test func cleanUpToDateIsNoOpButUnpushedCommitsStillRun() async {
    for ahead in [0, 1] {
      let store = GitWorkspaceStore()
      var actions = 0
      let completed = await store.publish(context: context) { method, _ in
        if method == "git.runStackedAction" {
          actions += 1
          return [
            "action": "commit_push", "commit": ["status": "skipped_no_changes"],
            "push": ["status": "pushed"],
          ]
        }
        return method == "vcs.listRefs"
          ? ["refs": []] : snapshot(files: false, ahead: ahead, upstream: true)
      }
      #expect(completed && actions == ahead)
      #expect(!store.message.isEmpty)
    }
  }

  @Test func invalidOrDetachedSnapshotNeverMutates() async {
    for state: [String: Any] in [
      ["isRepo": false], [:],
      [
        "isRepo": true, "refName": NSNull(), "hasUpstream": false,
        "aheadCount": 0, "behindCount": 0, "workingTree": ["files": []],
      ],
    ] {
      let store = GitWorkspaceStore()
      let completed = await store.publish(context: context) { method, _ in
        #expect(method != "git.runStackedAction")
        return method == "vcs.listRefs" ? ["refs": []] : state
      }
      #expect(!completed && !store.busy && !store.message.isEmpty)
    }
  }

  @Test func failedOrMalformedActionDoesNotRetryOrClaimSuccess() async {
    for malformed in [false, true] {
      let store = GitWorkspaceStore()
      var actions = 0
      let completed = await store.publish(context: context) { method, _ in
        if method == "git.runStackedAction" {
          actions += 1
          if malformed { return [:] }
          throw URLError(.timedOut)
        }
        return method == "vcs.listRefs"
          ? ["refs": []] : snapshot(files: true, ahead: 0, upstream: true)
      }
      #expect(!completed && actions == 1 && store.requiresRefresh)
      #expect(!store.busy && store.progress.isEmpty && store.message.contains("未自动重试"))
    }
  }

  @Test func explicitRetryAfterPartialFailureAlwaysRefreshesFirst() async {
    let store = GitWorkspaceStore()
    var actionIDs: [String] = []
    var calls: [String] = []
    for attempt in 0..<2 {
      let completed = await store.publish(context: context) { method, payload in
        calls.append(method)
        if method == "git.runStackedAction" {
          actionIDs.append(payload["actionId"] as? String ?? "")
          if attempt == 0 { throw URLError(.timedOut) }
          return [
            "action": "commit_push", "commit": ["status": "skipped_no_changes"],
            "push": ["status": "pushed"],
          ]
        }
        return method == "vcs.listRefs"
          ? ["refs": []] : snapshot(files: attempt == 0, ahead: 1, upstream: true)
      }
      #expect(completed == (attempt == 1))
    }
    #expect(actionIDs.count == 2 && Set(actionIDs).count == 2)
    #expect(!store.requiresRefresh && store.message == "已推送，工作区没有新增提交。")
    #expect(
      calls == [
        "vcs.refreshStatus", "vcs.listRefs", "git.runStackedAction",
        "vcs.refreshStatus", "vcs.listRefs", "git.runStackedAction",
        "vcs.refreshStatus", "vcs.listRefs",
      ])
  }

  @Test func successWithFailedReconciliationIsNotReportedAsFullyVerified() async {
    let store = GitWorkspaceStore()
    var acted = false
    let completed = await store.publish(context: context) { method, _ in
      if method == "git.runStackedAction" {
        acted = true
        return result
      }
      if acted { throw URLError(.notConnectedToInternet) }
      return method == "vcs.listRefs"
        ? ["refs": []] : snapshot(files: true, ahead: 0, upstream: true)
    }
    #expect(!completed && store.requiresRefresh && !store.busy)
    #expect(store.message.contains("已完成提交并推送，但状态刷新失败"))
  }
}

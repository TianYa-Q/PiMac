import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct BulkSettlementTests {
  @Test func onlyExplicitlyInactiveThreadsAreEligible() {
    let idle: [String: Any] = ["id": "t", "status": "idle"]
    for status in ["idle", "completed", "failed", "cancelled", "interrupted"] {
      var thread = idle
      thread["status"] = status
      #expect(WorkspaceModel.canBulkSettle(thread))
    }
    for status in [
      "queued", "preparing", "starting", "running", "waiting", "interrupting", "unknown",
    ] {
      var thread = idle
      thread["status"] = status
      #expect(!WorkspaceModel.canBulkSettle(thread))
    }
    for (key, value) in [
      ("activeRunId", "run" as Any),
      ("activityRunStatus", "running" as Any),
      ("pendingRuntimeRequest", ["id": "request"] as Any),
      ("pendingBackgroundTasks", [["id": "task"]] as Any),
      ("pendingBackgroundTasks", "invalid" as Any),
      ("settledOverride", "settled" as Any),
      ("settledAt", "2026-01-01T00:00:00Z" as Any),
      ("archivedAt", "2026-01-01T00:00:00Z" as Any),
      ("status", NSNull() as Any),
      ("id", "" as Any),
    ] {
      var thread = idle
      thread[key] = value
      #expect(!WorkspaceModel.canBulkSettle(thread))
    }
    var thread = idle
    thread["activeRunId"] = NSNull()
    thread["pendingRuntimeRequest"] = NSNull()
    thread["pendingBackgroundTasks"] = [[String: Any]]()
    #expect(WorkspaceModel.canBulkSettle(thread))
  }

  @Test func batchOverlapsRequestsWithBoundedConcurrencyAndRechecksState() async {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    var threads: [[String: Any]] = (0..<8).map {
      ["id": "\($0)", "status": "idle"]
    }
    workspace.server.applyShell(["threads": threads])
    var inFlight = 0
    var peak = 0
    var submitted: [String] = []
    let result = await workspace.performSettlement(paths: workspace.idleSessionPaths) { id in
      if submitted.isEmpty {
        // 首个请求尚未完成、后四个还在排队时，整批已经从 UI 移走。
        #expect(workspace.filteredSessions.isEmpty)
        #expect(workspace.filteredSessions(settled: true).isEmpty)
        #expect(workspace.idleSessionPaths.isEmpty)
        #expect(!workspace.canRestartSafely)
      }
      submitted.append(id)
      inFlight += 1
      peak = max(peak, inFlight)
      defer { inFlight -= 1 }
      // 首批请求挂起时，会话 4 开始工作；后续补位必须重新校验而不是照旧快照提交。
      threads[4]["status"] = "running"
      workspace.server.applyShell(["threads": threads])
      #expect(!workspace.filteredSessions.contains { $0.path == "t3:\(id)" })
      try await Task.sleep(for: .milliseconds(20))
      if id == "1" { throw T3DesktopClient.ClientError.rejected }
    }
    #expect(peak == 4)
    #expect(inFlight == 0)
    #expect(submitted.count == 7)
    #expect(Set(submitted).count == 7)
    #expect(!submitted.contains("4"))
    #expect(result.completed == 6)
    #expect(result.unconfirmed == 1)
    // 未确认失败不得伪造本地已完成状态。
    #expect(!WorkspaceModel.isSettled(workspace.server.thread("1")!))
    #expect(Set(workspace.filteredSessions.map(\.path)) == ["t3:1", "t3:4"])
    #expect(workspace.idleSessionPaths == ["t3:1"])
    #expect(workspace.pendingSettlementPaths.count == 6)
    for index in threads.indices where submitted.contains("\(index)") && index != 1 {
      threads[index]["settledOverride"] = "settled"
    }
    workspace.server.applyShell(["threads": threads])
    #expect(workspace.pendingSettlementPaths.isEmpty)
    #expect(workspace.filteredSessions(settled: true).count == 6)
  }

  @Test func bulkScopeIncludesAllProjectsRegardlessOfSidebarFilter() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    workspace.server.applyShell([
      "projects": [["id": "p1", "workspaceRoot": "/tmp/bulk-settle-p1"]],
      "threads": [
        ["id": "one", "projectId": "p1", "status": "completed"],
        ["id": "two", "projectId": "p2", "status": "idle"],
        ["id": "busy", "projectId": "p2", "status": "running"],
        [
          "id": "settled", "projectId": "p1", "status": "completed", "settledOverride": "settled",
        ],
      ],
    ])
    workspace.toggleProjectFilter(
      WorkspaceProject(url: URL(fileURLWithPath: "/tmp/bulk-settle-p1")))
    #expect(workspace.idleSessionPaths == ["t3:one", "t3:two"])
    // 离线点击不可创建写任务或改变本地完成状态。
    workspace.settleIdleSessions()
    #expect(!workspace.isSettlingIdleSessions)
    #expect(workspace.idleSessionPaths.count == 2)
  }
}

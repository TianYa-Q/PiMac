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
    for status in ["queued", "preparing", "starting", "running", "waiting", "interrupting", "unknown"] {
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

  @Test func bulkScopeIncludesAllProjectsRegardlessOfSidebarFilter() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    workspace.server.applyShell([
      "projects": [["id": "p1", "workspaceRoot": "/tmp/bulk-settle-p1"]],
      "threads": [
        ["id": "one", "projectId": "p1", "status": "completed"],
        ["id": "two", "projectId": "p2", "status": "idle"],
        ["id": "busy", "projectId": "p2", "status": "running"],
        ["id": "settled", "projectId": "p1", "status": "completed", "settledOverride": "settled"],
      ],
    ])
    workspace.toggleProjectFilter(WorkspaceProject(url: URL(fileURLWithPath: "/tmp/bulk-settle-p1")))
    #expect(workspace.idleSessionPaths == ["t3:one", "t3:two"])
    // 离线点击不可创建写任务或改变本地完成状态。
    workspace.settleIdleSessions()
    #expect(!workspace.isSettlingIdleSessions)
    #expect(workspace.idleSessionPaths.count == 2)
  }
}

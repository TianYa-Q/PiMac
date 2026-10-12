import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ThreadSettlementPresentationTests {
  @Test func manualAndAutomaticSettlementUseServerState() {
    #expect(!WorkspaceModel.isSettled(["settledOverride": NSNull(), "settledAt": NSNull()]))
    #expect(WorkspaceModel.isSettled(["settledOverride": "settled", "settledAt": NSNull()]))
    #expect(WorkspaceModel.isSettled(["settledOverride": NSNull(), "settledAt": "2026-01-01T00:00:00Z"]))
    #expect(!WorkspaceModel.isSettled(["settledOverride": "active", "settledAt": NSNull()]))
  }

  @Test func autoSettlementMovesRowsWithoutDiscardingConversation() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let active: [String: Any] = ["id": "active", "projectId": "project"]
    var completed: [String: Any] = ["id": "completed", "projectId": "project"]
    workspace.server.applyShell(["threads": [active, completed]])
    #expect(workspace.filteredSessions.count == 2)
    completed["settledAt"] = "2026-01-01T00:00:00Z"
    workspace.server.applyShell(["threads": [active, completed]])
    #expect(workspace.filteredSessions.map(\.path) == ["t3:active"])
    #expect(workspace.filteredSessions(settled: true).map(\.path) == ["t3:completed"])
    #expect(workspace.server.thread("completed") != nil)
    completed["settledAt"] = NSNull()
    completed["settledOverride"] = "active"
    workspace.server.applyShell(["threads": [active, completed]])
    #expect(workspace.filteredSessions.count == 2)
    #expect(workspace.filteredSessions(settled: true).isEmpty)
  }

  @Test func archivedRowsAreNotCompletedRowsAndInvalidateCache() {
    let cache = SessionCatalogCache()
    var row: [String: Any] = ["id": "thread", "projectId": "project"]
    cache.update(threads: [row])
    #expect(cache.sessions(projectID: "project").count == 1)
    row["archivedAt"] = "2026-01-01T00:00:00Z"
    cache.update(threads: [row])
    #expect(cache.sessions(projectID: "project").isEmpty)
  }
}

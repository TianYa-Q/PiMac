import Combine
import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct SessionCatalogCacheTests {
  @Test func streamingChangesDoNotRebuildCatalog() {
    let cache = SessionCatalogCache()
    var thread: [String: Any] = [
      "id": "one", "projectId": "project", "title": "Before",
      "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
    ]
    cache.update(threads: [thread])
    let original = cache.sessions(projectID: "project")
    thread["latestTurn"] = ["state": "running"]
    for _ in 0..<100 { cache.update(threads: [thread]) }
    #expect(cache.rebuildCount == 1)
    #expect(cache.sessions(projectID: "project") == original)
    thread["title"] = "After"
    cache.update(threads: [thread])
    #expect(cache.rebuildCount == 2)
    #expect(cache.sessions(projectID: "project").first?.title == "After")
  }

  @Test func projectMoveAndRemovalInvalidateCatalogs() {
    let cache = SessionCatalogCache()
    cache.update(threads: [["id": "one", "projectId": "old"]])
    cache.update(threads: [["id": "one", "projectId": "new"]])
    #expect(cache.sessions(projectID: "old").isEmpty)
    #expect(cache.sessions(projectID: "new").count == 1)
    cache.update(threads: [])
    #expect(cache.sessions(projectID: "new").isEmpty)
  }

  @Test func orderAndTimestampChangesInvalidateCatalog() {
    let cache = SessionCatalogCache()
    var rows: [[String: Any]] = [
      ["id": "one", "projectId": "p", "activeOrderKey": "a"],
      ["id": "two", "projectId": "p", "activeOrderKey": "b"],
    ]
    cache.update(threads: rows)
    rows[0]["activeOrderKey"] = "c"
    rows[0]["updatedAt"] = "2026-02-01T00:00:00Z"
    cache.update(threads: rows)
    #expect(cache.sessions(projectID: "p").map(\.path) == ["t3:two", "t3:one"])
    #expect(cache.rebuildCount == 2)
  }

  @Test func identicalCatalogDoesNotPublishAgain() {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    let rows = [SessionItem(path: "t3:one", title: "One", modifiedAt: .distantPast)]
    var publications = 0
    let observation = model.$sessions.dropFirst().sink { _ in publications += 1 }
    model.updateCatalog(rows)
    model.updateCatalog(rows)
    #expect(publications == 1)
    withExtendedLifetime(observation) {}
  }

  @Test func pollingUsesBoundedActiveAndIdleCadence() {
    #expect(T3DesktopClient.pollIntervalMilliseconds(hasRunningThread: true) == 500)
    #expect(T3DesktopClient.pollIntervalMilliseconds(hasRunningThread: false) == 2000)
  }
}

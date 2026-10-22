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
    rows[0]["latestMessageAt"] = "2026-02-01T00:00:00Z"
    cache.update(threads: rows)
    #expect(cache.sessions(projectID: "p").map(\.path) == ["t3:two", "t3:one"])
    #expect(cache.rebuildCount == 2)
  }

  @Test func messageTimeInvalidatesButLifecycleUpdatesDoNot() {
    let cache = SessionCatalogCache()
    var row: [String: Any] = [
      "id": "one", "projectId": "p", "createdAt": "2026-01-01T00:00:00Z",
      "latestMessageAt": "2026-01-01T01:00:00Z",
    ]
    cache.update(threads: [row])
    row["updatedAt"] = "2026-01-02T00:00:00Z"
    cache.update(threads: [row])
    #expect(cache.rebuildCount == 1)
    row["latestMessageAt"] = "2026-01-01T02:00:00Z"
    cache.update(threads: [row])
    #expect(cache.rebuildCount == 2)
    #expect(
      cache.sessions(projectID: "p").first?.modifiedAt
        == T3DesktopClient.date(row["latestMessageAt"]))
  }

  @Test func globalOrderingAndSettlementProjectionsShareTheCatalogOrder() {
    let cache = SessionCatalogCache()
    cache.update(threads: [
      ["id": "key-z", "projectId": "p", "activeOrderKey": "z"],
      [
        "id": "key-c", "projectId": "q", "activeOrderKey": "a",
        "createdAt": "2026-05-01T00:00:00Z",
      ],
      [
        "id": "key-b", "projectId": "p", "activeOrderKey": "a",
        "createdAt": "2026-03-01T00:00:00Z",
      ],
      [
        "id": "key-a", "projectId": "q", "activeOrderKey": "a",
        "createdAt": "2026-01-01T00:00:00Z", "settledOverride": "settled",
      ],
      [
        "id": "reopened", "projectId": "q", "createdAt": "2026-01-01T00:00:00Z",
        "unsettledAt": "2026-04-01T00:00:00Z",
      ],
      [
        "id": "recent", "projectId": "p", "createdAt": "2026-03-01T00:00:00Z",
        "settledAt": "invalid-but-still-settled",
      ],
      ["id": "bad-b", "projectId": "q", "createdAt": "invalid"],
      ["id": "bad-a", "projectId": "p", "createdAt": "invalid"],
      ["id": "orphan", "createdAt": "2026-02-01T00:00:00Z"],
      ["id": "archived", "projectId": "p", "archivedAt": "invalid"],
    ])
    #expect(
      cache.sessions(projectID: nil, settled: false).map(\.path) == [
        "t3:reopened", "t3:orphan", "t3:bad-a", "t3:bad-b", "t3:key-b", "t3:key-c", "t3:key-z",
      ])
    #expect(
      cache.sessions(projectID: nil, settled: true).map(\.path) == [
        "t3:recent", "t3:key-a",
      ])
    #expect(
      cache.sessions(projectID: "p").map(\.path) == [
        "t3:recent", "t3:bad-a", "t3:key-b", "t3:key-z",
      ])
    #expect(
      cache.sessions(projectID: "q", settled: false).map(\.path) == [
        "t3:reopened", "t3:bad-b", "t3:key-c",
      ])
    #expect(cache.sessions(projectID: "q", settled: true).map(\.path) == ["t3:key-a"])
    #expect(cache.sessions(projectID: "missing", settled: false).isEmpty)
  }

  @Test func projectionsFollowMetadataMutationsAndRemoval() {
    let cache = SessionCatalogCache()
    var rows: [[String: Any]] = [
      [
        "id": "one", "projectId": "p", "title": "Before",
        "createdAt": "2026-01-01T00:00:00Z",
      ],
      ["id": "two", "projectId": "q", "createdAt": "2026-02-01T00:00:00Z"],
    ]
    cache.update(threads: rows)
    #expect(cache.sessions(projectID: nil, settled: false).map(\.path) == ["t3:two", "t3:one"])
    rows[0]["projectId"] = "q"
    rows[0]["title"] = "After"
    rows[0]["unsettledAt"] = "2026-03-01T00:00:00Z"
    rows[0]["latestMessageAt"] = "2026-04-01T00:00:00Z"
    rows[1]["settledOverride"] = "settled"
    cache.update(threads: rows)
    #expect(cache.sessions(projectID: "p").isEmpty)
    #expect(cache.sessions(projectID: "q").map(\.path) == ["t3:one", "t3:two"])
    #expect(cache.sessions(projectID: nil, settled: false).first?.title == "After")
    #expect(
      cache.sessions(projectID: nil, settled: false).first?.modifiedAt
        == Date(timeIntervalSince1970: 1_775_001_600))
    #expect(cache.sessions(projectID: "q", settled: true).map(\.path) == ["t3:two"])
    rows[1].removeValue(forKey: "settledOverride")
    rows[1]["settledAt"] = "2026-04-01T00:00:00Z"
    rows[0]["archivedAt"] = "2026-04-01T00:00:00Z"
    cache.update(threads: rows)
    #expect(cache.sessions(projectID: nil, settled: false).isEmpty)
    #expect(cache.sessions(projectID: "q").map(\.path) == ["t3:two"])
    rows[1].removeValue(forKey: "settledAt")
    cache.update(threads: [rows[1]])
    #expect(cache.sessions(projectID: nil, settled: true).isEmpty)
    #expect(cache.sessions(projectID: "q", settled: false).map(\.path) == ["t3:two"])
    cache.update(threads: [])
    #expect(cache.sessions(projectID: nil, settled: false).isEmpty)
    #expect(cache.sessions(projectID: "q").isEmpty)
  }

  @Test func missingAndMalformedMessageTimestampsRemainDistinct() {
    let cache = SessionCatalogCache()
    var row: [String: Any] = [
      "id": "one", "projectId": "p", "createdAt": "2026-01-01T00:00:00Z",
      "latestMessageAt": 123,
    ]
    cache.update(threads: [row])
    #expect(cache.sessions(projectID: nil, settled: false).first?.modifiedAt == .distantPast)
    row["latestMessageAt"] = NSNull()
    cache.update(threads: [row])
    #expect(
      cache.sessions(projectID: nil, settled: false).first?.modifiedAt
        == Date(timeIntervalSince1970: 1_767_225_600))
    row["latestMessageAt"] = "invalid"
    cache.update(threads: [row])
    #expect(cache.sessions(projectID: "p").first?.modifiedAt == .distantPast)
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

import Foundation

/// Cache only sidebar metadata; message/run changes must not reparse every timestamp.
@MainActor
final class SessionCatalogCache {
  private struct Entry {
    let metadata: [[String?]]
    let sessions: [SessionItem]
  }
  private var entries: [String: Entry] = [:]
  private(set) var rebuildCount = 0

  func update(threads: [[String: Any]]) {
    let groups = Dictionary(grouping: threads) { $0["projectId"] as? String ?? "" }
    let remaining = entries.filter { groups[$0.key] != nil }
    if remaining.count != entries.count { rebuildCount += 1 }
    entries = remaining
    for (projectID, rows) in groups {
      let metadata = rows.map { row in
        ["id", "title", "createdAt", "unsettledAt", "activeOrderKey", "updatedAt"].map {
          row[$0] as? String
        }
      }
      guard entries[projectID]?.metadata != metadata else { continue }
      entries[projectID] = Entry(
        metadata: metadata,
        sessions: WorkspaceModel.sessionCatalog(threads: rows, projectID: projectID))
      rebuildCount += 1
    }
  }

  func sessions(projectID: String) -> [SessionItem] {
    entries[projectID]?.sessions ?? []
  }
}

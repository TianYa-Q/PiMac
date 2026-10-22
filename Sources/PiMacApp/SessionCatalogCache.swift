import Foundation

/// Cache only sidebar metadata; message/run changes must not reparse every timestamp.
@MainActor
final class SessionCatalogCache {
  private struct Projection {
    var all: [SessionItem] = []
    var active: [SessionItem] = []
    var settled: [SessionItem] = []

    mutating func append(_ item: SessionItem, settled: Bool) {
      all.append(item)
      if settled {
        self.settled.append(item)
      } else {
        active.append(item)
      }
    }
  }

  private struct Metadata: Equatable {
    let fields: [String?]
    let hasMessageTimestamp: Bool
  }

  private struct Snapshot {
    let metadata: [Metadata]
    let allProjects: Projection
    let projects: [String: Projection]
  }
  private var snapshot: Snapshot?
  private(set) var rebuildCount = 0

  func update(threads: [[String: Any]]) {
    let metadata = threads.map { row in
      // 缺失消息时间回退到创建时间，非字符串的损坏值则保留 distantPast，不能合并缓存键。
      Metadata(
        fields: [
          "id", "projectId", "title", "createdAt", "unsettledAt", "activeOrderKey",
          "latestMessageAt", "settledOverride", "settledAt", "archivedAt", "autoSettleDisabledAt",
        ].map { row[$0] as? String },
        hasMessageTimestamp: row["latestMessageAt"] != nil && !(row["latestMessageAt"] is NSNull))
    }
    guard snapshot?.metadata != metadata else { return }

    // 仅在元数据改变时解析、排序一次；各投影按全局顺序追加，避免项目间排序规则分叉。
    let sessions = WorkspaceModel.sessionCatalog(threads: threads, projectID: nil)
    var ownership: [String: (projectID: String?, settled: Bool)] = [:]
    for thread in threads {
      guard let id = thread["id"] as? String else { continue }
      ownership["t3:\(id)"] = (thread["projectId"] as? String, WorkspaceModel.isSettled(thread))
    }
    var allProjects = Projection()
    var projects: [String: Projection] = [:]
    for item in sessions {
      guard let owner = ownership[item.path] else { continue }
      allProjects.append(item, settled: owner.settled)
      if let projectID = owner.projectID {
        projects[projectID, default: Projection()].append(item, settled: owner.settled)
      }
    }
    // 整体替换派生快照，项目迁移和删除不会留下旧投影；Server 仍是唯一数据来源。
    snapshot = Snapshot(metadata: metadata, allProjects: allProjects, projects: projects)
    rebuildCount += 1
  }

  func sessions(projectID: String) -> [SessionItem] {
    snapshot?.projects[projectID]?.all ?? []
  }

  func sessions(projectID: String?, settled: Bool) -> [SessionItem] {
    let projection: Projection?
    if let projectID {
      projection = snapshot?.projects[projectID]
    } else {
      projection = snapshot?.allProjects
    }
    return (settled ? projection?.settled : projection?.active) ?? []
  }
}

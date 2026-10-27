import Foundation

/// 只保存可阅读的正文，不缓存权限、交互请求、发件箱或运行状态。
@MainActor
final class ConversationPresentationCache {
  struct Snapshot: Codable {
    let projectPath: String
    let threadID: String
    let title: String
    let messages: [ChatEntry]
  }

  private static let storageKey = "t3ConversationPresentationCache.v1"
  private let defaults: UserDefaults
  private let maximumCount: Int
  private let maximumBytes: Int
  private var snapshots: [Snapshot] = []
  private var saveTask: Task<Void, Never>?

  init(defaults: UserDefaults, maximumCount: Int = 16, maximumBytes: Int = 12 * 1024 * 1024) {
    self.defaults = defaults
    self.maximumCount = maximumCount
    self.maximumBytes = maximumBytes
    if let data = defaults.data(forKey: Self.storageKey) {
      do {
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        snapshots = Array(
          try JSONDecoder().decode([Snapshot].self, from: data).suffix(maximumCount))
      } catch {
        // 缓存损坏不是合法空会话；放弃这份展示副本，仍由实时请求恢复正文。
        NSLog("Conversation presentation cache unavailable: %@", error.localizedDescription)
      }
    }
  }

  func snapshot(project: URL, threadID: String) -> Snapshot? {
    let path = project.standardizedFileURL.path
    guard
      let index = snapshots.firstIndex(where: {
        $0.projectPath == path && $0.threadID == threadID
      })
    else { return nil }
    let snapshot = snapshots.remove(at: index)
    snapshots.append(snapshot)
    return snapshot
  }

  func store(project: URL, threadID: String, title: String, messages: [ChatEntry]) {
    let path = project.standardizedFileURL.path
    func readable(_ entry: ChatEntry) -> ChatEntry {
      var entry = entry
      entry.isRunning = false
      entry.childToolEntries = entry.childToolEntries.map(readable)
      return entry
    }
    let messages = messages.map(readable)
    if let existing = snapshots.first(where: {
      $0.projectPath == path && $0.threadID == threadID
    }), existing.title == title, existing.messages == messages {
      return
    }
    snapshots.removeAll { $0.projectPath == path && $0.threadID == threadID }
    snapshots.append(
      Snapshot(
        projectPath: path, threadID: threadID, title: title, messages: messages))
    if snapshots.count > maximumCount { snapshots.removeFirst(snapshots.count - maximumCount) }
    // 流式更新立即进入内存；磁盘写入合并，避免每个 token 都重写偏好文件。
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
      self?.persist()
    }
  }

  func persist() {
    saveTask?.cancel()
    saveTask = nil
    do {
      var data = try JSONEncoder().encode(snapshots)
      // 按完整会话淘汰，不截断单条消息而伪造一份看似完整的历史。
      while data.count > maximumBytes, !snapshots.isEmpty {
        snapshots.removeFirst()
        data = try JSONEncoder().encode(snapshots)
      }
      defaults.set(data, forKey: Self.storageKey)
    } catch {
      NSLog("Conversation presentation cache save failed: %@", error.localizedDescription)
    }
  }
}

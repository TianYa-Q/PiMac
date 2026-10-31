import Foundation

/// 每个会话只允许一次刷新在途；慢会话不能阻塞其他会话或列表。
@MainActor
final class ThreadRefreshScheduler {
  private final class Lane {
    var requested = true
    var task: Task<Void, Error>?
    var refresh: @MainActor () async throws -> Void

    init(refresh: @escaping @MainActor () async throws -> Void) { self.refresh = refresh }
  }
  private var lanes: [String: Lane] = [:]
  private var suspensions: Set<UUID> = []
  var isSuspended: Bool { !suspensions.isEmpty }

  /// 前台写入优先：取消昂贵后台读取，嵌套写入各自释放自己的暂停身份。
  func suspend() -> UUID {
    let token = UUID()
    suspensions.insert(token)
    for lane in lanes.values { lane.task?.cancel() }
    lanes.removeAll()
    return token
  }

  func resume(_ token: UUID) { suspensions.remove(token) }

  @discardableResult
  func request(
    _ threadID: String, refresh: @escaping @MainActor () async throws -> Void
  ) -> Task<Void, Error> {
    guard !isSuspended else { return Task { throw CancellationError() } }
    if let lane = lanes[threadID], let task = lane.task {
      // 写入可能发生在旧快照读取途中，必须再读一次，不能只等待旧请求。
      lane.requested = true
      lane.refresh = refresh
      return task
    }
    let lane = Lane(refresh: refresh)
    let task = Task {
      defer { if self.lanes[threadID] === lane { self.lanes[threadID] = nil } }
      while lane.requested {
        try Task.checkCancellation()
        lane.requested = false
        try await lane.refresh()
      }
    }
    lane.task = task
    lanes[threadID] = lane
    return task
  }

  func waitForCurrent() async throws {
    let tasks = lanes.values.compactMap(\.task)
    for task in tasks { try await task.value }
  }

  func cancel(_ threadID: String) { lanes.removeValue(forKey: threadID)?.task?.cancel() }

  func cancelAll() {
    for lane in lanes.values { lane.task?.cancel() }
    lanes.removeAll()
    suspensions.removeAll()
  }
}

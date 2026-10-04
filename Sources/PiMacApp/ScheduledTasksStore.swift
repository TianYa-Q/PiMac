import Combine
import Foundation

@MainActor
final class ScheduledTasksStore: ObservableObject {
  typealias RPC = (String, [String: Any]) async throws -> [String: Any]
  @Published private(set) var tasks: [DesktopScheduledTask] = []
  @Published private(set) var isLoading = false
  @Published private(set) var isMutating = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var hasLoaded = false
  @Published private(set) var requiresRefresh = false
  @Published private(set) var lastRefreshedAt: Date?
  private let rpc: RPC

  init(rpc: @escaping RPC) { self.rpc = rpc }

  func refresh() async {
    guard !Task.isCancelled, !isLoading, !isMutating else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      try await load()
      errorMessage = nil
      requiresRefresh = false
    } catch is CancellationError {
    } catch {
      requiresRefresh = true
      errorMessage = "定时任务刷新失败，列表可能已过期。请检查 Server 连接后刷新。"
    }
  }

  private func load() async throws {
    let result = try await rpc("scheduledTasks.list", [:])
    guard let rows = result["tasks"] as? [[String: Any]] else {
      throw T3DesktopClient.ClientError.rejected
    }
    try Task.checkCancellation()
    let next = try rows.map(DesktopScheduledTask.init)
    guard Set(next.map(\.id)).count == next.count else {
      throw T3DesktopClient.ClientError.rejected
    }
    tasks = next.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    hasLoaded = true
    lastRefreshedAt = Date()
  }

  func save(_ draft: ScheduledTaskDraft) async -> Bool {
    guard !Task.isCancelled, !isMutating, !isLoading, !requiresRefresh else { return false }
    guard let payload = try? draft.payload() else {
      errorMessage = draft.validationMessage ?? "任务配置无效。"
      return false
    }
    return await mutate("scheduledTasks.upsert", payload, expected: draft.original)
  }
  func setEnabled(_ task: DesktopScheduledTask) async {
    _ = await mutate(
      "scheduledTasks.setEnabled", ["id": task.id, "enabled": !task.enabled], expected: task)
  }
  func delete(_ task: DesktopScheduledTask) async {
    _ = await mutate("scheduledTasks.delete", ["id": task.id], expected: task)
  }
  func runNow(_ task: DesktopScheduledTask) async {
    _ = await mutate("scheduledTasks.runNow", ["id": task.id], expected: task)
  }

  private func mutate(
    _ method: String, _ payload: [String: Any], expected: DesktopScheduledTask? = nil
  ) async -> Bool {
    // Enforce the refresh barrier here too, not only in the view: queued actions
    // must not dispatch against stale state after an unknown mutation outcome.
    guard !Task.isCancelled, !isMutating, !isLoading, !requiresRefresh else { return false }
    isMutating = true
    errorMessage = nil
    defer { isMutating = false }
    // One lock covers preflight, dispatch and reconciliation. Releasing it
    // between awaits would allow a second click to validate the same snapshot.
    if let expected {
      do {
        try await load()
      } catch is CancellationError {
        // Preflight is read-only; nothing has been dispatched and no outcome is ambiguous.
        return false
      } catch {
        requiresRefresh = true
        errorMessage = "操作前核对任务失败，未发送修改。请检查连接后刷新。"
        return false
      }
      guard let current = tasks.first(where: { $0.id == expected.id }),
        current.hasSameConfiguration(as: expected)
      else {
        requiresRefresh = true
        errorMessage = "任务已变更或移除。请刷新后重新打开编辑／确认，避免覆盖其他客户端的修改。"
        return false
      }
      if method == "scheduledTasks.runNow", current.raw["lastRunStatus"] as? String == "running" {
        errorMessage = "任务正在派发，请等待完成后再执行。"
        return false
      }
    }
    // Cancellation before dispatch is definitive. After dispatch, retain the
    // unknown-outcome barrier even for CancellationError: the Server may have acted.
    guard !Task.isCancelled else { return false }
    do {
      _ = try await rpc(method, payload)
    } catch {
      // An interrupted transport does not prove rejection. Never retry a mutation automatically.
      requiresRefresh = true
      errorMessage = "操作未确认，可能已生效。请刷新并检查任务／会话后再操作；不会自动重试。"
      return false
    }
    do { try await load() } catch {
      requiresRefresh = true
      errorMessage = "操作已被 Server 接受，但列表刷新失败。请手动刷新。"
    }
    return true
  }
}

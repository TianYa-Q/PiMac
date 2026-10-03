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
  private let rpc: RPC

  init(rpc: @escaping RPC) { self.rpc = rpc }

  func refresh() async {
    guard !isLoading, !isMutating else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      try await load()
      errorMessage = nil
    } catch is CancellationError {
    } catch {
      errorMessage = "定时任务刷新失败，列表可能已过期。请检查 Server 连接后刷新。"
    }
  }

  private func load() async throws {
    let result = try await rpc("scheduledTasks.list", [:])
    guard let rows = result["tasks"] as? [[String: Any]] else {
      throw T3DesktopClient.ClientError.rejected
    }
    let next = try rows.map(DesktopScheduledTask.init)
    tasks = next.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    hasLoaded = true
  }

  func save(_ draft: ScheduledTaskDraft) async -> Bool {
    guard let payload = try? draft.payload() else {
      errorMessage = draft.validationMessage ?? "任务配置无效。"
      return false
    }
    return await mutate("scheduledTasks.upsert", payload)
  }
  func setEnabled(_ task: DesktopScheduledTask) async {
    _ = await mutate("scheduledTasks.setEnabled", ["id": task.id, "enabled": !task.enabled])
  }
  func delete(_ task: DesktopScheduledTask) async {
    _ = await mutate("scheduledTasks.delete", ["id": task.id])
  }
  func runNow(_ task: DesktopScheduledTask) async {
    _ = await mutate("scheduledTasks.runNow", ["id": task.id])
  }

  private func mutate(_ method: String, _ payload: [String: Any]) async -> Bool {
    guard !isMutating, !isLoading else { return false }
    isMutating = true
    errorMessage = nil
    defer { isMutating = false }
    do {
      _ = try await rpc(method, payload)
    } catch {
      // An interrupted transport does not prove rejection. Never retry a mutation automatically.
      errorMessage = "操作未确认，可能已生效。请刷新并检查任务／会话后再操作；不会自动重试。"
      return false
    }
    do { try await load() } catch {
      errorMessage = "操作已被 Server 接受，但列表刷新失败。请手动刷新。"
    }
    return true
  }
}

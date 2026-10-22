import Combine
import Foundation

struct WorkspaceSkillContext: Equatable {
  let instanceID: String
  let projectCwd: String
  let threadID: String?
}

@MainActor
final class WorkspaceSkillCache: ObservableObject {
  struct Key: Hashable {
    let instanceID: String
    let cwd: String
  }

  struct Success: Equatable {
    let skills: [ComposerSkill]
    let validatedAt: Date
  }

  enum State: Equatable {
    case idle
    case loading(previous: Success?)
    case ready(Success)
    case failed(previous: Success?, message: String, attemptedAt: Date)

    var success: Success? {
      switch self {
      case .idle: nil
      case .loading(let previous), .failed(let previous, _, _): previous
      case .ready(let success): success
      }
    }
    var skills: [ComposerSkill] { success?.skills ?? [] }
    var hasLoaded: Bool { success != nil }
    var isLoading: Bool {
      if case .loading = self { return true }
      return false
    }
    var error: String? {
      if case .failed(_, let message, _) = self { return message }
      return nil
    }
  }

  enum Reload { case ifStale, force }

  private struct Request {
    let id: UUID
    let forced: Bool
    let task: Task<Void, Never>
  }

  @Published private(set) var states: [Key: State] = [:]
  private var pending: [Key: Request] = [:]
  private var generation = UUID()
  private let clock: () -> Date

  init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

  func state(for key: Key) -> State { states[key] ?? .idle }

  @discardableResult
  func preload(
    key: Key, reload: Reload, now: Date,
    discover: @escaping @MainActor () async throws -> Success
  ) -> Task<Void, Never>? {
    if let request = pending[key] {
      if reload == .ifStale || request.forced { return request.task }
      request.task.cancel()
    } else if reload == .ifStale {
      let state = state(for: key)
      let date: Date?
      if case .failed(_, _, let attemptedAt) = state {
        date = attemptedAt
      } else {
        date = state.success?.validatedAt
      }
      if let date, (0..<300).contains(now.timeIntervalSince(date)) { return nil }
    }
    let previous = state(for: key).success
    let current = generation
    let id = UUID()
    states[key] = .loading(previous: previous)
    let task = Task { [self] in
      do {
        let success = try await discover()
        guard generation == current, pending[key]?.id == id else { return }
        states[key] = .ready(success)
      } catch {
        guard generation == current, pending[key]?.id == id else { return }
        states[key] = .failed(
          previous: previous, message: error.localizedDescription, attemptedAt: clock())
      }
      // 强制刷新可替换自动请求；旧任务既不能发布，也不能清除新任务的句柄。
      if generation == current, pending[key]?.id == id { pending[key] = nil }
    }
    pending[key] = Request(id: id, forced: reload == .force, task: task)
    return task
  }

  func reset() {
    generation = UUID()
    for request in pending.values { request.task.cancel() }
    pending.removeAll()
    states.removeAll()
  }
}

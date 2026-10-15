import Combine
import Foundation

struct TextGenerationModelSettings: Decodable, Equatable {
  enum Status: String, Decodable {
    case selected
    case noVisibleModels = "no-visible-models"
  }
  struct Selection: Decodable, Equatable {
    let instanceId: String
    let model: String
  }
  struct Candidate: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
  }
  let status: Status
  let selection: Selection?
  let candidates: [Candidate]

  init(status: Status, selection: Selection?, candidates: [Candidate]) {
    self.status = status
    self.selection = selection
    self.candidates = candidates
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    status = try values.decode(Status.self, forKey: .status)
    selection = try values.decodeIfPresent(Selection.self, forKey: .selection)
    candidates = try values.decode([Candidate].self, forKey: .candidates)
    let ids = candidates.map(\.id)
    guard ids.allSatisfy({ $0.contains("/") }), Set(ids).count == ids.count,
      (status == .selected && selection?.instanceId == "pi" && ids.contains(selection?.model ?? ""))
        || (status == .noVisibleModels && selection == nil && candidates.isEmpty)
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid title model settings"))
    }
  }
  private enum CodingKeys: String, CodingKey { case status, selection, candidates }
}

/// 只缓存服务端已确认的快照；不写 UserDefaults，也不在保存失败时乐观改变选择。
@MainActor
final class TextGenerationModelStore: ObservableObject {
  @Published private(set) var snapshot: TextGenerationModelSettings?
  @Published private(set) var busy = false
  @Published private(set) var error = ""
  private var generation = UUID()
  private var pendingRefresh: (() async throws -> TextGenerationModelSettings)?

  func update(refresh: Bool, _ operation: @escaping () async throws -> TextGenerationModelSettings)
    async
  {
    if busy {
      // 可见性变更可能发生在读取或保存期间；合并为最新的一次重读，而不是丢弃。
      if refresh { pendingRefresh = operation }
      return
    }
    let current = generation
    busy = true
    defer { if generation == current { busy = false } }
    var next = operation
    while generation == current {
      error = ""
      do {
        let result = try await next()
        guard generation == current else { return }
        // 已请求重读说明当前响应可能过时，不能再发布旧选择。
        if pendingRefresh == nil { snapshot = result }
      } catch {
        guard generation == current else { return }
        if pendingRefresh == nil { self.error = "标题模型设置未确认：\(error.localizedDescription)" }
      }
      guard let pending = pendingRefresh else { return }
      pendingRefresh = nil
      next = pending
    }
  }

  func reset() {
    generation = UUID()
    pendingRefresh = nil
    snapshot = nil
    error = ""
    busy = false
  }
}

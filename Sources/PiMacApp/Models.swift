import Foundation
import SwiftUI

enum ConnectionState: Equatable {
  case disconnected
  case connecting
  case connected
  case failed(String)

  var label: String {
    switch self {
    case .disconnected: "未连接"
    case .connecting: "连接中"
    case .connected: "已连接"
    case .failed(let message): "连接失败：\(message)"
    }
  }

  var color: Color {
    switch self {
    case .connected: .green
    case .connecting: .orange
    case .disconnected, .failed: .red
    }
  }
}

enum ChatEntryKind: Equatable, Codable, Sendable {
  case user
  case assistant
  case thinking
  case tool
  case compaction
  case system
}

struct ChatEntry: Identifiable, Equatable, Codable, Sendable {
  let id: String
  var kind: ChatEntryKind
  var title: String
  var text: String
  var isRunning = false
  var isError = false
  var toolName: String? = nil
  var toolInput: String? = nil
  var parentToolEntryID: String? = nil
  var childToolEntries: [ChatEntry] = []
  var nestedCalls: [NestedToolCall] = []
  var nestedCallsComplete = true
  var diff: String? = nil
  var attachments: [PromptAttachment] = []
  var htmlRender: T3HTMLRender? = nil
  var htmlDocument: String? = nil
  var htmlRenderError: String? = nil
  var modelProvider: String? = nil
  var modelID: String? = nil
  var timestamp: Date? = .now
  var runID: String? = nil

  /// Only explicit parent links determine ownership; concurrent top-level tools stay separate.
  static func groupingToolEntries(_ entries: [ChatEntry]) -> [ChatEntry] {
    let ids = Set(entries.map(\.id))
    let children = Dictionary(
      grouping: entries.filter {
        $0.parentToolEntryID != nil && ids.contains($0.parentToolEntryID!)
          && $0.parentToolEntryID != $0.id
      }, by: { $0.parentToolEntryID! })
    // 深链只维护当前 DFS 路径，避免每一层复制整个祖先集合；退出分支时恢复，兄弟节点互不影响。
    // 唯一 ID 下每个节点只有一个父节点，从根可达的部分不可能有环；只有重复 ID 才需逐层防环。
    let needsCycleCheck = ids.count != entries.count
    var ancestors: Set<String> = []
    func grouped(_ entry: ChatEntry) -> ChatEntry {
      var result = entry
      guard let descendants = children[entry.id] else {
        result.childToolEntries = []
        return result
      }
      if needsCycleCheck { ancestors.insert(entry.id) }
      defer { if needsCycleCheck { ancestors.remove(entry.id) } }
      // 单子节点的常见深链无需排序，也不分配 filter/map 的中间数组。
      let ordered =
        descendants.count > 1
        ? descendants.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
        : descendants
      result.childToolEntries = []
      result.childToolEntries.reserveCapacity(ordered.count)
      for child in ordered where !needsCycleCheck || !ancestors.contains(child.id) {
        result.childToolEntries.append(grouped(child))
      }
      return result
    }
    return entries.filter {
      guard let parent = $0.parentToolEntryID else { return true }
      return parent == $0.id || !ids.contains(parent)
    }.map { grouped($0) }
  }

  var modelLabel: String? {
    guard let modelID else { return nil }
    return modelProvider.map { "\(modelID) · \($0)" } ?? modelID
  }
}

enum QueuedPromptDelivery: String, Codable, Sendable {
  case steer
  case followUp

  var label: String {
    switch self {
    case .steer: "工具调用后"
    case .followUp: "任务完成后"
    }
  }
}

/// Server run identity is opaque; it is not necessarily a UUID.
struct ServerQueuedPrompt: Identifiable, Sendable {
  let id: String
  let text: String
  let attachments: [PromptAttachment]
  var submissionState: SubmissionState = .confirmed

  enum SubmissionState: Sendable {
    case submitting, unconfirmed, confirmed

    var label: String {
      switch self {
      case .submitting: "正在提交"
      case .unconfirmed: "提交未确认"
      case .confirmed: "Server 队列"
      }
    }
  }
}

struct QueuedPrompt: Identifiable, Sendable {
  let id: UUID
  let text: String
  let rpcText: String
  let delivery: QueuedPromptDelivery
  let attachments: [PromptAttachment]
  var waitsForCompaction = false
  var remoteMessageID: String? = nil
  var remoteMessageDate: Date? = nil
}

struct PromptAttachment: Identifiable, Hashable, Codable, Sendable {
  var id = UUID()
  let url: URL
  let mimeType: String?
  var replyImagePath: String? = nil

  var isImage: Bool { mimeType?.hasPrefix("image/") == true }

  var composerReference: String {
    if isImage {
      if url.lastPathComponent.hasPrefix("pi-clipboard-") {
        return "[[粘贴图片 \(id.uuidString.prefix(4).uppercased())]]"
      }
      return "[[图片：\(url.lastPathComponent)]]"
    }
    return "[[文件：\(url.lastPathComponent)]]"
  }
}

struct PiModel: Identifiable, Hashable {
  static let thinkingLevelOrder = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

  let provider: String
  let modelId: String
  let name: String
  let reasoning: Bool
  let api: String?
  let thinkingLevels: [String]
  let defaultContextWindow: Int?

  var id: String { "\(provider)/\(modelId)" }

  init(
    provider: String,
    modelId: String,
    name: String,
    reasoning: Bool = false,
    api: String? = nil,
    thinkingLevels: [String]? = nil,
    defaultContextWindow: Int? = nil
  ) {
    self.provider = provider
    self.modelId = modelId
    self.name = name
    self.reasoning = reasoning
    self.api = api
    self.defaultContextWindow = defaultContextWindow
    self.thinkingLevels =
      thinkingLevels ?? (reasoning ? Array(Self.thinkingLevelOrder.prefix(5)) : ["off"])
  }
}

struct SessionStats: Codable {
  let cost: Double?
  let contextPercent: Double?
  let totalTokens: Int
  let inputTokens: Int
  let cacheReadTokens: Int
  let cacheWriteTokens: Int
  var outputTokensPerSecond: Double? = nil
  var contextWindow: Int? = nil
  var contextIsEstimated: Bool? = nil

  var cacheHitPercent: Double? {
    let promptTokens = inputTokens + cacheReadTokens + cacheWriteTokens
    guard promptTokens > 0 else { return nil }
    return Double(cacheReadTokens) / Double(promptTokens) * 100
  }
}

struct CodexUsageWindow: Hashable {
  let remainingPercent: Double
  let resetAt: Date?
  let windowSeconds: Double?
}

struct CodexResetCredits: Hashable {
  let availableCount: Int
  let expirations: [Date]
}

struct CodexAccountStatus: Identifiable, Hashable {
  let name: String
  let isActive: Bool
  let isDefault: Bool
  let isHidden: Bool
  let primary: CodexUsageWindow?
  let secondary: CodexUsageWindow?
  let resetCredits: CodexResetCredits?
  let error: String?
  var capturedAt: Date? = nil

  var id: String { name }
}

struct SessionItem: Codable, Identifiable, Hashable, Sendable {
  let path: String
  let title: String
  let modifiedAt: Date

  var id: String { path }
}

enum ExtensionDialogKind {
  case select(options: [String])
  case confirm(message: String)
  case input(initialText: String, placeholder: String, multiline: Bool)
}

struct ExtensionDialog: Identifiable {
  /// Local presentation identity; RPC request IDs can collide across processes.
  let presentationID = UUID()
  let id: String
  let title: String
  let kind: ExtensionDialogKind
}

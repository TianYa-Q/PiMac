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

enum ChatEntryKind: Sendable {
  case user
  case assistant
  case thinking
  case tool
  case compaction
  case system
}

struct ChatEntry: Identifiable, Sendable {
  let id: String
  var kind: ChatEntryKind
  var title: String
  var text: String
  var isRunning = false
  var isError = false
  var toolName: String? = nil
  var toolInput: String? = nil
  var diff: String? = nil
  var attachments: [PromptAttachment] = []
  var modelProvider: String? = nil
  var modelID: String? = nil

  var modelLabel: String? {
    guard let modelID else { return nil }
    return modelProvider.map { "\(modelID) · \($0)" } ?? modelID
  }
}

enum QueuedPromptDelivery: String, Sendable {
  case steer
  case followUp

  var label: String {
    switch self {
    case .steer: "工具调用后"
    case .followUp: "任务完成后"
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
}

struct PromptAttachment: Identifiable, Hashable, Sendable {
  let id = UUID()
  let url: URL
  let mimeType: String?

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
  let thinkingLevels: [String]

  var id: String { "\(provider)/\(modelId)" }

  init(
    provider: String,
    modelId: String,
    name: String,
    reasoning: Bool = false,
    thinkingLevels: [String]? = nil
  ) {
    self.provider = provider
    self.modelId = modelId
    self.name = name
    self.reasoning = reasoning
    self.thinkingLevels =
      thinkingLevels ?? (reasoning ? Array(Self.thinkingLevelOrder.prefix(5)) : ["off"])
  }
}

struct SessionStats {
  let cost: Double
  let contextPercent: Double?
  let totalTokens: Int
}

struct CodexUsageWindow: Hashable {
  let remainingPercent: Double
  let resetAt: Date?
  let windowSeconds: Double?
}

struct GeminiQuota: Identifiable, Hashable {
  let remainingPercent: Double
  let resetAt: Date?
  let window: String?

  var id: String { "\(window ?? "quota")-\(resetAt?.timeIntervalSince1970 ?? 0)" }
}

struct GeminiUsageStatus: Hashable {
  let isConfigured: Bool
  let isActive: Bool
  let quotas: [GeminiQuota]
  let error: String?
}

struct CodexAccountStatus: Identifiable, Hashable {
  let name: String
  let isActive: Bool
  let isDefault: Bool
  let isHidden: Bool
  let primary: CodexUsageWindow?
  let secondary: CodexUsageWindow?
  let error: String?

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
  let id: String
  let title: String
  let kind: ExtensionDialogKind
}

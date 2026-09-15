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

enum ChatEntryKind {
  case user
  case assistant
  case thinking
  case tool
  case system
}

struct ChatEntry: Identifiable {
  let id: String
  var kind: ChatEntryKind
  var title: String
  var text: String
  var isRunning = false
  var isError = false
}

struct PiModel: Identifiable, Hashable {
  let provider: String
  let modelId: String
  let name: String

  var id: String { "\(provider)/\(modelId)" }
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

struct SessionItem: Identifiable, Hashable, Sendable {
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

import Foundation

/// Activity reflects RPC events, not a promise that the upstream connection is healthy.
/// Empty thinking_start/end events are significant: Codex may only send encrypted reasoning.
struct StreamActivity: Equatable {
  enum Phase: String {
    case waiting = "等待模型响应"
    case thinking = "正在推理"
    case responding = "正在生成回复"
    case preparingTool = "正在生成工具调用"
    case executingTool = "正在执行工具"
    case retrying = "正在自动重试"
  }

  private(set) var phase: Phase?
  private(set) var startedAt: Date?
  private(set) var lastResponseAt: Date?

  mutating func consume(_ event: [String: Any], now: Date = .now) {
    // Limit observable timestamp changes to once per second, without retaining payloads.
    let now = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
    switch event["type"] as? String {
    case "agent_start":
      self = StreamActivity(phase: .waiting, startedAt: now)
    case "agent_settled":
      self = StreamActivity()
    case "message_start":
      guard (event["message"] as? [String: Any])?["role"] as? String == "assistant" else { return }
      phase = .waiting
      startedAt = now
      lastResponseAt = nil
    case "message_update":
      guard let update = event["assistantMessageEvent"] as? [String: Any] else { return }
      switch update["type"] as? String {
      case "thinking_start", "thinking_delta", "thinking_end": phase = .thinking
      case "text_start", "text_delta", "text_end": phase = .responding
      case "toolcall_start", "toolcall_delta", "toolcall_end": phase = .preparingTool
      default: return
      }
      if startedAt == nil { startedAt = now }
      lastResponseAt = now
    case "tool_execution_start", "tool_execution_update":
      phase = .executingTool
    case "tool_execution_end":
      phase = .waiting
      startedAt = now
      lastResponseAt = nil
    case "auto_retry_start":
      phase = .retrying
      startedAt = now
      lastResponseAt = nil
    case "auto_retry_end":
      phase = .waiting
      startedAt = now
      lastResponseAt = nil
    default: break
    }
  }

  func label(at now: Date) -> String? {
    guard let phase else { return nil }
    // Tools and retry backoff are not provider streaming; don't call them a silent model.
    if phase == .executingTool || phase == .retrying { return phase.rawValue + "…" }
    let elapsed = max(0, Int(now.timeIntervalSince(startedAt ?? now)))
    let silence = lastResponseAt.map { max(0, Int(now.timeIntervalSince($0))) }
    let duration = elapsed >= 60 ? "\(elapsed / 60)分\(elapsed % 60)秒" : "\(elapsed)秒"
    if let silence {
      return "\(phase.rawValue) · \(duration) · \(silence)秒前收到响应"
        + (silence >= 30 ? "（等待新数据）" : "")
    }
    return "\(phase.rawValue) · \(duration)（尚未收到流式数据）"
  }
}

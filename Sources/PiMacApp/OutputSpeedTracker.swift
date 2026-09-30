import Foundation

/// Provider-reported output tokens / time spent in assistant requests (not tool execution).
/// Includes request latency and reasoning tokens; never guesses tokens from character counts.
struct OutputSpeedTracker {
  private var startedAt: TimeInterval?
  private var completedTokens = 0
  private var completedDuration: TimeInterval = 0
  private var currentTokens = 0
  private(set) var tokensPerSecond: Double?

  mutating func reset() { self = Self() }

  mutating func consume(_ event: [String: Any], now: TimeInterval) {
    let type = event["type"] as? String
    if type == "message_start",
      let message = event["message"] as? [String: Any],
      message["role"] as? String == "assistant"
    {
      startedAt = now
      currentTokens = 0
    } else if type == "message_update" {
      guard let delta = event["assistantMessageEvent"] as? [String: Any] else { return }
      if startedAt == nil { startedAt = now }
      let message = delta["partial"] as? [String: Any]
      let usage = (event["usage"] as? [String: Any]) ?? (message?["usage"] as? [String: Any])
      currentTokens = max(currentTokens, (usage?["output"] as? NSNumber)?.intValue ?? 0)
      update(now: now)
    } else if type == "message_end",
      let message = event["message"] as? [String: Any],
      message["role"] as? String == "assistant"
    {
      guard let start = startedAt else { return }
      let usage = message["usage"] as? [String: Any]
      let tokens = max(0, (usage?["output"] as? NSNumber)?.intValue ?? currentTokens)
      let duration = now - start
      // Missing usage must not dilute the speed of requests with known usage.
      if tokens > 0 && duration > 0 {
        completedTokens += tokens
        completedDuration += duration
      }
      startedAt = nil
      currentTokens = 0
      if completedDuration > 0 {
        tokensPerSecond = Double(completedTokens) / completedDuration
      }
    }
  }

  private mutating func update(now: TimeInterval) {
    guard let start = startedAt, currentTokens > 0, now > start else { return }
    tokensPerSecond = Double(completedTokens + currentTokens) / (completedDuration + now - start)
  }
}

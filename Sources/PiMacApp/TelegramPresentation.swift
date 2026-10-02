import CryptoKit
import Foundation

/// Layout shared by Telegram command cards, without starting or changing sessions.
enum TelegramPresentation {
  static let projectPageSize = 8
  static let modelPageSize = 8
  static let accountPageSize = 4

  enum ChoiceKind: String, CaseIterable {
    case project
    case model = "modelid"
    case account = "accountid"
  }

  static func choiceCommand(_ kind: ChoiceKind, value: String) -> String {
    let digest = SHA256.hash(data: Data("\(kind.rawValue)\u{0}\(value)".utf8))
    let identifier = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    return "\(kind.rawValue):\(identifier)"
  }

  static func choiceKind(_ command: String) -> ChoiceKind? {
    let parts = command.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let kind = ChoiceKind(rawValue: String(parts[0])),
      parts[1].count == 32, parts[1].allSatisfy({ $0.isASCII && $0.isHexDigit })
    else { return nil }
    return kind
  }

  static func choiceIndex(_ command: String, kind: ChoiceKind, values: [String]) -> Int? {
    guard choiceKind(command) == kind else { return nil }
    let matches = values.indices.filter { choiceCommand(kind, value: values[$0]) == command }
    // Missing and duplicate identities are unsafe; never silently fall back to an index.
    return matches.count == 1 ? matches.first : nil
  }

  static func selectionFeedback(label: String, value: String, confirmed: Bool) -> String {
    confirmed
      ? "✅ \(label)已切换\n\(compactLabel(value, limit: 48, preserveSuffix: true))"
      : "⏳ \(label)切换待确认\n目标：\(compactLabel(value, limit: 48, preserveSuffix: true))\n点「状态」核实，无需重复操作。"
  }

  enum TaskOutcome: Equatable {
    case completed, stopped, failed, endedWithoutReply
  }

  static func taskOutcome(stopReason: String?, hasReply: Bool) -> TaskOutcome {
    if stopReason == "aborted" { return .stopped }
    if stopReason == "error" { return .failed }
    return hasReply ? .completed : .endedWithoutReply
  }

  static func resultText(outcome: TaskOutcome, reply: String?, error: String?) -> String {
    switch outcome {
    case .completed:
      return reply ?? "任务结束 · 无文本回复"
    case .stopped:
      return "⏹ 任务已停止" + (reply.map { "\n\n部分回复：\n\n\($0)" } ?? "\n无文本回复")
    case .failed:
      let detail =
        error.flatMap { $0.isEmpty ? nil : compactLabel($0, limit: 240) }
        ?? "请在 Mac 查看错误。"
      return "❌ 任务执行失败\n\(detail)" + (reply.map { "\n\n部分回复：\n\n\($0)" } ?? "")
    case .endedWithoutReply:
      return "任务结束 · 无文本回复\n详情见 Mac 执行记录。"
    }
  }

  static func completionSummary(
    outcome: TaskOutcome, delivered: Bool?, elapsed: String, queuedCount: Int
  ) -> String {
    let title: String
    switch outcome {
    case .completed: title = "✅ 任务完成"
    case .stopped: title = "⏹ 任务已停止"
    case .failed: title = "❌ 任务执行失败"
    case .endedWithoutReply: title = "任务结束 · 无文本回复"
    }
    let delivery: String
    switch delivered {
    case true?: delivery = "结果已发送 · 回复可继续原会话"
    case false?: delivery = "结果未送达 · 自动重试，无需重发"
    case nil: delivery = "结果发送中 · 无需重发"
    }
    var lines = [title, "耗时  \(elapsed)", delivery]
    if queuedCount > 0 { lines.append("排队  \(queuedCount) 条 · 自动继续") }
    return lines.joined(separator: "\n")
  }

  static func isSessionAction(_ command: String) -> Bool {
    ["/new", "/compact", "/stop"].contains(command)
      || ["model:", "modelid:", "thinking:", "account:", "accountid:", "session:"].contains(
        where: command.hasPrefix)
  }

  static func canPerform(
    _ command: String, card: TelegramMessageSessionStore.Location?,
    selected: TelegramMessageSessionStore.Location?
  ) -> Bool {
    guard isSessionAction(command) else { return true }
    guard let card, let selected else { return false }
    return card == selected
  }

  static func taskNotice(
    project: String, originalSession: Bool, position: Int? = nil, preview: String = "",
    attachmentCount: Int = 0, waitingForConnection: Bool = false,
    waitingForConfirmation: Bool = false
  ) -> String {
    // Prefixes are also used to restore queued receipt cards after a delivery retry.
    var lines = [
      position == nil ? "✅ 任务已提交" : "📥 任务已排队",
      "项目  \(compactLabel(project, limit: 32))",
      originalSession ? "目标  原会话 · 不改默认选择" : "目标  当前会话",
    ]
    if let position { lines.append("排队  第 \(max(1, position)) 位") }
    let preview = compactLabel(preview, limit: 48)
    if !preview.isEmpty { lines.append("摘要  \(preview)") }
    if attachmentCount > 0 { lines.append("附件  \(attachmentCount) 个") }
    if position != nil {
      if waitingForConfirmation {
        lines.append("\n待 Mac 确认，随后自动执行。")
      } else if waitingForConnection {
        lines.append("\n连接重试中，无需重发。")
      } else {
        lines.append("\n按序执行，完成后回传。")
      }
      lines.append("可编辑原消息；取消仅限此条。")
    } else {
      lines.append("\n完成后回传。")
    }
    return lines.joined(separator: "\n")
  }

  static func compactLabel(_ text: String, limit: Int, preserveSuffix: Bool = false) -> String {
    guard limit > 0 else { return "" }
    let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard text.count > limit else { return text }
    guard preserveSuffix, limit >= 5 else { return String(text.prefix(limit - 1)) + "…" }
    let suffixCount = min(12, (limit - 1) / 3)
    return String(text.prefix(limit - suffixCount - 1)) + "…" + String(text.suffix(suffixCount))
  }

  static func boundedPercent(_ value: Double) -> Double? {
    value.isFinite ? min(100, max(0, value)) : nil
  }

  static func percent(_ value: Double) -> String {
    boundedPercent(value).map { "\(Int($0.rounded()))%" } ?? "待统计"
  }

  static func meter(_ value: Double) -> String? {
    guard let value = boundedPercent(value) else { return nil }
    let filled = Int((value / 100 * 8).rounded())
    return String(repeating: "▰", count: filled) + String(repeating: "▱", count: 8 - filled)
  }

  static func cacheAge(updatedAt: Date?, now: Date) -> String {
    guard let updatedAt else { return "缓存更新时间未知" }
    let seconds = max(0, now.timeIntervalSince(updatedAt))
    guard seconds.isFinite else { return "缓存更新时间未知" }
    if seconds < 60 { return "刚刚同步" }
    if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前同步" }
    if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时前同步" }
    return "超过 1 天未同步"
  }

  struct Page: Equatable {
    let number: Int
    let count: Int
    let start: Int
    let end: Int
  }

  static func page(_ requested: Int, count: Int, size: Int) -> Page {
    let size = max(1, size)
    let count = max(0, count)
    let pages = max(1, count / size + (count % size == 0 ? 0 : 1))
    let number = min(max(1, requested), pages)
    let start = (number - 1) * size
    return Page(number: number, count: pages, start: start, end: start + min(size, count - start))
  }

  static func button(_ title: String, _ action: String) -> [String: String] {
    ["text": title, "callback_data": action]
  }

  static func navigation(_ page: Page, command: String) -> [[String: String]] {
    var buttons: [[String: String]] = []
    if page.number > 1 { buttons.append(button("‹ 上一页", "\(command) \(page.number - 1)")) }
    if page.number < page.count { buttons.append(button("下一页 ›", "\(command) \(page.number + 1)")) }
    return buttons
  }

  static func footer(command: String, running: Bool, hasSession: Bool) -> [[[String: String]]] {
    // One recognizable icon per destination; short labels keep navigation scannable.
    var rows = [
      [button("📊 状态", "/status"), button("📁 项目", "/projects"), button("💬 会话", "/sessions")],
      [button("🤖 模型", "/model"), button("🧠 推理", "/thinking"), button("📈 额度", "/usage")],
    ]
    let isStatus =
      ["/status", "/new", "/stop", "/compact", "/queue"].contains(command)
      || command.hasPrefix("select:") || command.hasPrefix("project:")
      || command.hasPrefix("session:")
      || command.hasPrefix("model:") || command.hasPrefix("modelid:")
      || command.hasPrefix("thinking:")
    if hasSession
      && (isStatus || command == "/sessions" || command == "/help" || command == "/start")
    {
      if running {
        rows.append([button("＋ 新会话", "/new"), button("📥 队列", "/queue"), button("❔ 帮助", "/help")])
        // A destructive action gets its own row, away from frequently used navigation.
        rows.append([button("⏹ 停止当前任务并取消排队", "/stop")])
      } else {
        rows.append([button("＋ 新会话", "/new"), button("🗜 压缩", "/compact"), button("❔ 帮助", "/help")])
      }
    } else if command != "/help" && command != "/start" {
      rows.append(
        hasSession && running
          ? [button("📥 队列", "/queue"), button("❔ 帮助", "/help")]
          : [button("❔ 帮助", "/help")])
    }
    return rows
  }
}

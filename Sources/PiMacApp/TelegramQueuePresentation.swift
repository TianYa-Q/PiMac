import Foundation

/// Read-only queue snapshots; cancelling uses task IDs, never a mutable list position.
enum TelegramQueuePresentation {
  static let pageSize = 5

  struct Item {
    let id: UUID
    let preview: String
    let attachmentCount: Int
    let receivedAt: Date
  }

  static func cancellationCommand(id: UUID, page: Int) -> String {
    "qcancel:\(id.uuidString):\(min(1_000_000, max(1, page)))"
  }

  static func cancellation(_ command: String) -> (id: UUID, page: Int)? {
    let parts = command.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "qcancel", let id = UUID(uuidString: String(parts[1])),
      let page = Int(parts[2]), page > 0, page <= 1_000_000
    else { return nil }
    return (id, page)
  }

  static func waitAge(receivedAt: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(receivedAt))
    guard seconds.isFinite else { return "等待时长未知" }
    if seconds < 60 { return "不到 1 分钟" }
    if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟" }
    if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时" }
    return "超过 1 天"
  }

  static func card(
    project: String, session: String, items: [Item], localQueueCount: Int,
    blocker: String, page requestedPage: Int, now: Date = .now
  ) -> String {
    let page = TelegramPresentation.page(requestedPage, count: items.count, size: pageSize)
    var lines = [
      "等待队列 · \(items.count) 条 · \(page.number)/\(page.count) 页",
      "项目  \(TelegramPresentation.compactLabel(project, limit: 32))",
      "会话  \(TelegramPresentation.compactLabel(session, limit: 32))", "",
    ]
    if items.isEmpty {
      lines.append("暂无等待任务")
    } else {
      let blocker = TelegramPresentation.compactLabel(blocker, limit: 64)
      if !blocker.isEmpty { lines.append(blocker) }
      for (offset, item) in items.dropFirst(page.start).prefix(page.end - page.start).enumerated() {
        let preview = TelegramPresentation.compactLabel(item.preview, limit: 48)
        lines.append("\n\(page.start + offset + 1). \(preview.isEmpty ? "附件任务" : preview)")
        lines.append(
          "   等待 \(waitAge(receivedAt: item.receivedAt, now: now))"
            + (item.attachmentCount > 0 ? " · 附件 \(item.attachmentCount) 个" : ""))
      }
      lines.append("\n按序执行 · 可编辑原消息\n取消仅限等待任务，不停止执行。")
    }
    if localQueueCount > 0 {
      lines.append("\nPi 另有 \(localQueueCount) 条排队 · Mac 管理")
    }
    return lines.joined(separator: "\n")
  }

  static func keyboard(items: [Item], page requestedPage: Int) -> [[[String: String]]] {
    let page = TelegramPresentation.page(requestedPage, count: items.count, size: pageSize)
    var rows = items.dropFirst(page.start).prefix(page.end - page.start).enumerated().map {
      offset, item in
      [
        TelegramPresentation.button(
          "✕ 取消第 \(page.start + offset + 1) 条",
          cancellationCommand(id: item.id, page: page.number))
      ]
    }
    let navigation = TelegramPresentation.navigation(page, command: "/queue")
    if !navigation.isEmpty { rows.append(navigation) }
    rows.append([TelegramPresentation.button("↻ 刷新队列", "/queue \(page.number)")])
    return rows
  }
}

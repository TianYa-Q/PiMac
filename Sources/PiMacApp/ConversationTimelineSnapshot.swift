final class ConversationTimelineSnapshot {
  let rows: [ConversationTimelineRow]
  let rowIDs: [String]
  let lastTurnID: String?

  init(messages: [ChatEntry], children: [ConversationSubagent], hasMoreHistory: Bool) {
    // Shell 含全部子会话，正文却可能只有近期窗口；不能把未载入的旧委派挤到页首。
    // 使用创建时间而非状态/完成时间，确保任务完成或更新不会改变其历史位置。
    // 缺失时间的任务无法判断所属页，保留既有的末尾展示，不猜测发生时间。
    let windowStart = messages.compactMap(\.timestamp).filter { $0 != .distantPast }.min()
    let visibleChildren = children.filter { child in
      guard hasMoreHistory, let createdAt = child.createdAt else { return true }
      guard let windowStart else { return false }
      return createdAt >= windowStart
    }
    let rows = ConversationTimelineRow.build(messages: messages, children: visibleChildren)
    self.rows = rows
    rowIDs = rows.map(\.id)
    lastTurnID =
      rows.reversed().lazy.compactMap { row -> String? in
        if case .turn(let turn) = row { return turn.id }
        return nil
      }.first
  }
}

final class ConversationTimelineSnapshot {
  let rows: [ConversationTimelineRow]
  let rowIDs: [String]
  let lastTurnID: String?

  init(messages: [ChatEntry], children: [ConversationSubagent]) {
    let rows = ConversationTimelineRow.build(messages: messages, children: children)
    self.rows = rows
    rowIDs = rows.map(\.id)
    lastTurnID =
      rows.reversed().lazy.compactMap { row -> String? in
        if case .turn(let turn) = row { return turn.id }
        return nil
      }.first
  }
}

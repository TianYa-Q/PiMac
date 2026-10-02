import Foundation

struct ConversationTurn: Identifiable, Equatable {
  let entries: [ChatEntry]
  let id: String
  let user: ChatEntry?
  let finalAssistant: ChatEntry?
  let activity: [ChatEntry]
  let supplementaryEntries: [ChatEntry]

  init(entries: [ChatEntry]) {
    self.entries = entries
    id = entries.first?.id ?? "empty-turn"
    user = entries.first(where: { $0.kind == .user })
    let finalAssistant = entries.last(where: { $0.kind == .assistant })
    self.finalAssistant = finalAssistant
    activity = entries.filter {
      $0.kind == .thinking || $0.kind == .tool
        || ($0.kind == .assistant && $0.id != finalAssistant?.id)
    }
    supplementaryEntries = entries.filter { $0.kind == .system || $0.kind == .compaction }
  }

  static func group(_ messages: [ChatEntry]) -> [ConversationTurn] {
    var turns: [ConversationTurn] = []
    var current: [ChatEntry] = []
    for entry in messages {
      // Account management is a UI action, not a conversational prompt.
      // Keep the command in session history, but omit its chat bubble.
      if entry.kind == .user,
        entry.text.trimmingCharacters(in: .whitespacesAndNewlines) == "/accounts",
        entry.attachments.isEmpty
      {
        continue
      }
      if entry.kind == .user, !current.isEmpty {
        turns.append(ConversationTurn(entries: current))
        current = []
      }
      current.append(entry)
    }
    if !current.isEmpty { turns.append(ConversationTurn(entries: current)) }
    return turns
  }
}

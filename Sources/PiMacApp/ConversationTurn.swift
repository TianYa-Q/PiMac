import Foundation

struct ConversationTurn: Identifiable, Equatable {
  let entries: [ChatEntry]
  let id: String
  let user: ChatEntry?
  let finalAssistant: ChatEntry?
  let htmlRenders: [ChatEntry]
  let activity: [ChatEntry]
  let supplementaryEntries: [ChatEntry]

  init(entries: [ChatEntry]) {
    self.entries = entries
    id = entries.first?.id ?? "empty-turn"
    user = entries.first(where: { $0.kind == .user })
    htmlRenders = entries.filter { $0.htmlRender != nil }
    let finalAssistant = entries.last(where: { $0.kind == .assistant && $0.htmlRender == nil })
    self.finalAssistant = finalAssistant
    activity = entries.filter {
      $0.kind == .thinking || $0.kind == .tool
        || ($0.kind == .assistant && $0.htmlRender == nil && $0.id != finalAssistant?.id)
    }
    supplementaryEntries = entries.filter { $0.kind == .system || $0.kind == .compaction }
  }

  static func group(_ messages: [ChatEntry]) -> [ConversationTurn] {
    var turns: [ConversationTurn] = []
    var current: [ChatEntry] = []
    for entry in messages {
      // 后台唤醒可以开启没有用户消息的新运行；不能把上次运行的正式答复降为过程消息。
      if let runID = entry.runID,
        let previousRunID = current.last(where: { $0.runID != nil })?.runID,
        runID != previousRunID
      {
        turns.append(ConversationTurn(entries: current))
        current = []
      }
      // 这些已知命令只控制账户、额度或压缩，不是发给模型的任务；原始历史不变。
      // 不按斜杠前缀一概隐藏，附带文件或多行任务说明的输入也保留。
      if entry.kind == .user, entry.attachments.isEmpty {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = text.split(maxSplits: 1, whereSeparator: \.isWhitespace).first
        if !text.contains(where: \.isNewline), let command,
          ["/accounts", "/usage", "/compact"].contains(String(command))
        {
          // 隐藏气泡仍保留轮次边界，避免执行结果并入上一条正常回复。
          if !current.isEmpty { turns.append(ConversationTurn(entries: current)) }
          current = []
          continue
        }
      }
      // 系统通知和压缩标记属于发生时的数据流，而非整轮对话的页脚。
      // 两侧分别成组，避免后续正常回复或工具活动被渲染到旧异常之前；
      // 通知确实是最后一条时，自然仍显示在底部。
      if entry.kind == .compaction || entry.kind == .system {
        if !current.isEmpty { turns.append(ConversationTurn(entries: current)) }
        turns.append(ConversationTurn(entries: [entry]))
        current = []
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

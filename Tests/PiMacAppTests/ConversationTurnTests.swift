import Testing

@testable import PiMacApp

struct ConversationTurnTests {
  @Test func hidesAccountManagementCommandBubble() {
    let command = ChatEntry(id: "command", kind: .user, title: "你", text: " /accounts\n")
    #expect(ConversationTurn.group([command]).isEmpty)
    let reply = ChatEntry(id: "reply", kind: .assistant, title: "Pi", text: "账户管理")
    let turns = ConversationTurn.group([command, reply])
    #expect(turns.count == 1)
    #expect(turns.first?.user == nil)
    #expect(turns.first?.finalAssistant == reply)
  }

  @Test func compactionStaysBetweenEarlierAndLaterWork() {
    let prompt = ChatEntry(id: "user", kind: .user, title: "你", text: "继续")
    let before = ChatEntry(id: "before", kind: .assistant, title: "Pi", text: "之前")
    let compact = ChatEntry(id: "compact", kind: .compaction, title: "上下文已压缩", text: "摘要")
    let tool = ChatEntry(id: "tool", kind: .tool, title: "read", text: "之后")
    let after = ChatEntry(id: "after", kind: .assistant, title: "Pi", text: "完成")
    let turns = ConversationTurn.group([prompt, before, compact, tool, after])
    #expect(turns.map(\.id) == ["user", "compact", "tool"])
    #expect(turns[0].finalAssistant == before)
    #expect(turns[1].entries == [compact])
    #expect(turns[2].activity == [tool])
    #expect(turns[2].finalAssistant == after)
    #expect(ConversationTurn.group([compact, compact]).count == 2)
  }

  @Test func recoveredNoticeStaysBeforeSubsequentWork() {
    let prompt = ChatEntry(id: "user", kind: .user, title: "你", text: "继续")
    let before = ChatEntry(id: "before", kind: .tool, title: "bash", text: "失败")
    let notice = ChatEntry(
      id: "notice", kind: .system, title: "Provider recovered", text: "连接中断", isError: true)
    let tool = ChatEntry(id: "tool", kind: .tool, title: "read", text: "正常输出")
    let after = ChatEntry(id: "after", kind: .assistant, title: "Pi", text: "完成")
    let turns = ConversationTurn.group([prompt, before, notice, tool, after])
    #expect(turns.map(\.id) == ["user", "notice", "tool"])
    #expect(turns[0].activity == [before])
    #expect(turns[1].supplementaryEntries == [notice])
    #expect(turns[2].activity == [tool])
    #expect(turns[2].finalAssistant == after)
  }

  @Test func trailingAndConsecutiveNoticesKeepTheirOrder() {
    let reply = ChatEntry(id: "reply", kind: .assistant, title: "Pi", text: "回复")
    let error = ChatEntry(id: "error", kind: .system, title: "错误", text: "连接中断", isError: true)
    let recovered = ChatEntry(
      id: "recovered", kind: .system, title: "Provider recovered", text: "已恢复")
    let compact = ChatEntry(id: "compact", kind: .compaction, title: "上下文已压缩", text: "摘要")
    let turns = ConversationTurn.group([reply, error, recovered, compact])
    #expect(turns.map(\.entries) == [[reply], [error], [recovered], [compact]])
    #expect(turns[0].finalAssistant == reply)
    #expect(turns[1].supplementaryEntries == [error])
    #expect(turns[2].supplementaryEntries == [recovered])
    #expect(ConversationTurn.group([error]).first?.supplementaryEntries == [error])
  }

  @Test func preservesOtherMessages() {
    let prompt = ChatEntry(id: "prompt", kind: .user, title: "你", text: "解释 /accounts")
    let reply = ChatEntry(id: "reply", kind: .assistant, title: "Pi", text: "/accounts")
    #expect(ConversationTurn.group([prompt, reply]).first?.entries == [prompt, reply])
  }
}

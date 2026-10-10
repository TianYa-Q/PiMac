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

  @Test func preservesOtherMessages() {
    let prompt = ChatEntry(id: "prompt", kind: .user, title: "你", text: "解释 /accounts")
    let reply = ChatEntry(id: "reply", kind: .assistant, title: "Pi", text: "/accounts")
    #expect(ConversationTurn.group([prompt, reply]).first?.entries == [prompt, reply])
  }
}

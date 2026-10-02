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

  @Test func preservesOtherMessages() {
    let prompt = ChatEntry(id: "prompt", kind: .user, title: "你", text: "解释 /accounts")
    let reply = ChatEntry(id: "reply", kind: .assistant, title: "Pi", text: "/accounts")
    #expect(ConversationTurn.group([prompt, reply]).first?.entries == [prompt, reply])
  }
}

import Foundation
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

  @Test(arguments: [
    "/accounts", " /accounts switch Work \n", "/accounts login", "/usage",
    "/usage refresh", "/usage cached json", "/compact", "/compact 保留实现细节",
    "/accounts\tswitch Work",
  ])
  func hidesKnownControlCommands(text: String) {
    let command = ChatEntry(id: "command", kind: .user, title: "你", text: text)
    #expect(ConversationTurn.group([command]).isEmpty)
  }

  @Test(arguments: [
    "/review 检查代码", "/accounts-extra", "/usage-report", "/compaction", "/pimac-fast on",
    "/accounts\n请解释这个命令", "/compact\r\n然后检查代码", "解释 /usage", "/", "",
  ])
  func preservesTasksAndUnknownCommands(text: String) {
    let prompt = ChatEntry(id: "prompt", kind: .user, title: "你", text: text)
    #expect(ConversationTurn.group([prompt]).first?.user == prompt)
  }

  @Test func preservesControlTextWithAttachmentsAndNonUserOutput() {
    let attachment = PromptAttachment(
      url: URL(fileURLWithPath: "/tmp/control-command-fixture.txt"), mimeType: "text/plain")
    let prompt = ChatEntry(
      id: "prompt", kind: .user, title: "你", text: "/accounts", attachments: [attachment])
    let reply = ChatEntry(id: "reply", kind: .assistant, title: "Pi", text: "/usage")
    #expect(ConversationTurn.group([prompt, reply]).first?.entries == [prompt, reply])
  }

  @Test func hiddenCommandsKeepResultsSeparateFromEarlierConversation() {
    let prompt = ChatEntry(id: "prompt", kind: .user, title: "你", text: "检查任务")
    let reply = ChatEntry(id: "reply", kind: .assistant, title: "Pi", text: "已完成")
    let command = ChatEntry(id: "command", kind: .user, title: "你", text: "/accounts switch Work")
    let result = ChatEntry(id: "result", kind: .tool, title: "notify", text: "已切换账户")
    let failedCommand = ChatEntry(id: "failed", kind: .user, title: "你", text: "/usage refresh")
    let failure = ChatEntry(
      id: "failure", kind: .system, title: "刷新失败", text: "连接失败", isError: true)
    let compactCommand = ChatEntry(id: "compact-command", kind: .user, title: "你", text: "/compact")
    let compact = ChatEntry(id: "compact", kind: .compaction, title: "上下文已压缩", text: "摘要")
    let messages = [
      prompt, reply, command, result, failedCommand, failure, compactCommand, compact,
    ]
    let turns = ConversationTurn.group(messages)
    #expect(turns.map(\.entries) == [[prompt, reply], [result], [failure], [compact]])
    #expect(turns[1].user == nil)
    #expect(turns[2].supplementaryEntries.first?.isError == true)
    // 展示过滤不得改写持久历史或用户输入。
    #expect(messages.count == 8)
    #expect(messages[2].text == "/accounts switch Work")
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

import Foundation
import Testing
@testable import PiMacApp

struct MCPToolInputTests {
  private let name = "mcp__t3-code__delegate_task"
  private var arguments: [String: Any] {
    ["task": "检查参数\n并验证历史记录", "mode": "async",
     "target": ["providerInstanceId": "pi", "model": "example"],
     "path": "/tmp/review", "enabled": true, "optional": NSNull()]
  }

  @Test func preservesAllCustomToolArgumentsIncludingPathAndNestedValues() throws {
    let input = try #require(AppModel.toolInputText(toolName: name, args: arguments))
    let decoded = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? NSDictionary
    #expect(decoded == arguments as NSDictionary)
    #expect(input.contains("\n"))
    let empty = try #require(AppModel.toolInputText(toolName: name, args: [:]))
    #expect(try JSONSerialization.jsonObject(with: Data(empty.utf8)) as? NSDictionary == [:])
    #expect(AppModel.toolInputText(toolName: name, args: nil) == nil)
    #expect(AppModel.toolInputText(toolName: name, args: "{\"mode\":\"async\"}") == "{\"mode\":\"async\"}")
  }

  @Test func restoresMCPArgumentsFromHistoryAndNestedMetadata() throws {
    let entries = AppModel.chatEntries(from: [
      ["role": "assistant", "content": [
        ["type": "toolCall", "id": "mcp", "name": name, "arguments": arguments]
      ]],
      ["role": "toolResult", "toolCallId": "mcp", "toolName": name, "content": []],
    ])
    let input = try #require(entries.first?.toolInput)
    #expect(input == AppModel.toolInputText(toolName: name, args: arguments))
    let nested = NestedToolCall.from(["calls": [
      ["id": "mcp", "name": name, "arguments": arguments, "status": "success"]
    ]])
    #expect(nested.first?.input == input)
  }

  @MainActor
  @Test func officialDynamicToolArgumentsSurviveRunningAndCompletedProjection() throws {
    for status in ["running", "completed"] {
      let detail = T3V2Presentation.detail(["projection": [
        "thread": ["id": "thread"],
        "visibleTurnItems": [["item": [
          "id": "mcp", "runId": "run", "type": "dynamic_tool", "toolName": name,
          "status": status, "input": arguments, "output": "",
        ]]],
      ]])
      let model = AppModel()
      model.currentSessionPath = "t3:thread"
      model.apply(detail)
      let entry = try #require(model.messages.first)
      #expect(entry.toolInput == AppModel.toolInputText(toolName: name, args: arguments))
      #expect(entry.isRunning == (status == "running"))
    }
  }
}

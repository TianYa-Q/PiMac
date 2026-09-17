import Foundation
import Testing

@testable import PiMacApp

struct ToolResultTests {
  @Test
  func preservesAssistantFailureAsVisibleTranscriptEntry() throws {
    let entry = try #require(
      AppModel.chatEntry(from: [
        "role": "assistant",
        "content": [],
        "stopReason": "error",
        "errorMessage": "Codex error: The usage limit has been reached",
      ])
    )

    #expect(entry.kind == .system)
    #expect(entry.isError)
    #expect(entry.text == "Codex error: The usage limit has been reached")
  }

  @Test
  func hidesTransientErrorWhenAutomaticRetryContinues() {
    let entries = AppModel.chatEntries(from: [
      [
        "role": "assistant",
        "content": [],
        "stopReason": "error",
        "errorMessage": "terminated",
      ],
      [
        "role": "assistant",
        "content": [["type": "text", "text": "重试成功"]],
        "stopReason": "stop",
      ],
    ])

    #expect(entries.count == 1)
    #expect(entries.first?.kind == .assistant)
    #expect(entries.first?.text == "重试成功")
  }

  @Test
  func preservesFinalErrorAfterRetriesAreExhausted() {
    let entries = AppModel.chatEntries(from: [
      [
        "role": "assistant",
        "content": [],
        "stopReason": "error",
        "errorMessage": "terminated",
      ],
      [
        "role": "assistant",
        "content": [],
        "stopReason": "error",
        "errorMessage": "terminated",
      ],
    ])

    #expect(entries.count == 1)
    #expect(entries.first?.isError == true)
    #expect(entries.first?.text == "terminated")
  }

  @Test
  func formatsBashCommandAndReadRange() {
    #expect(
      AppModel.toolInputText(
        toolName: "bash", args: ["command": "swift test", "timeout": 120]
      ) == "$ swift test"
    )
    #expect(
      AppModel.toolInputText(
        toolName: "read", args: ["path": "Sources/App.swift", "offset": 40, "limit": 20]
      ) == "Sources/App.swift:40-59"
    )
  }

  @Test
  func restoresToolInputFromAssistantCallHistory() throws {
    let messages: [PiRPCClient.JSON] = [
      [
        "role": "assistant",
        "content": [
          [
            "type": "toolCall",
            "id": "bash-history",
            "name": "bash",
            "arguments": ["command": "rg -n TODO Sources"],
          ]
        ],
      ],
      [
        "role": "toolResult",
        "toolCallId": "bash-history",
        "toolName": "bash",
        "content": [["type": "text", "text": "Sources/App.swift:10:// TODO"]],
      ],
    ]

    let entry = try #require(AppModel.chatEntries(from: messages).first)
    #expect(entry.toolInput == "$ rg -n TODO Sources")
  }

  @Test
  func restoresCompleteTruncatedBashOutputFromBackingFile() throws {
    let fullOutput = "first line\n" + String(repeating: "complete output ", count: 5_000)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pi-mac-tool-result-\(UUID().uuidString).log")
    try Data(fullOutput.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let message: PiRPCClient.JSON = [
      "role": "toolResult",
      "toolCallId": "bash-test",
      "toolName": "bash",
      "content": [["type": "text", "text": "short tail only"]],
      "details": [
        "truncation": ["truncated": true],
        "fullOutputPath": url.path,
      ],
    ]

    let entry = try #require(AppModel.chatEntry(from: message))
    #expect(entry.text == fullOutput)
  }
}

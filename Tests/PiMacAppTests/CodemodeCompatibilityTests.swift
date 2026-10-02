import Foundation
import Testing

@testable import PiMacApp

struct CodemodeCompatibilityTests {
  private let png =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="

  @Test func codeIsDisplayedWithoutJSONEscaping() {
    let code = "const rows = await tools.read({path: 'README.md'});\ntext(rows);"
    #expect(AppModel.toolInputText(toolName: "codemode", args: ["code": code]) == code)
    #expect(AppModel.toolInputText(toolName: "codemode", args: code) == code)
    #expect(AppModel.toolInputText(toolName: "codemode", args: ["other": code]) == nil)
  }

  @Test func persistedCodeAndNestedCallsAreRestored() throws {
    let code = "text(await tools.read({path: 'README.md'}));"
    let entries = AppModel.chatEntries(from: [
      [
        "role": "assistant",
        "content": [
          [
            "type": "toolCall", "id": "code-history",
            "name": "codemode", "arguments": ["code": code],
          ]
        ],
      ],
      [
        "role": "toolResult", "toolCallId": "code-history", "toolName": "codemode",
        "content": [["type": "text", "text": "Script completed"]],
        "nestedCalls": [
          "complete": true,
          "calls": [
            [
              "id": "code-history/1", "name": "read", "arguments": ["path": "README.md"],
              "status": "ok",
            ]
          ],
        ],
      ],
    ])
    let entry = try #require(entries.first)
    #expect(entry.toolInput == code)
    #expect(entry.nestedCalls.count == 1)
    #expect(entry.nestedCalls.first?.input == "README.md")
  }

  @Test func generatedToolImageIsAnAttachmentNotBase64Text() throws {
    let entry = try #require(
      AppModel.chatEntry(from: [
        "role": "toolResult", "toolCallId": "code-image", "toolName": "codemode",
        "content": [
          ["type": "text", "text": "Script completed"],
          ["type": "image", "data": png, "mimeType": "image/png"],
        ],
      ]))
    #expect(entry.text == "Script completed")
    let attachment = try #require(entry.attachments.first)
    #expect(attachment.isImage)
    #expect(try Data(contentsOf: attachment.url) == Data(base64Encoded: png))
    #expect(!entry.text.contains(png))
  }

  @Test @MainActor func liveToolResultKeepsCodeAndGeneratedImage() throws {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    let code = "image(await getImage());"
    model.handleToolEvent(
      [
        "toolCallId": "code-live", "toolName": "codemode", "args": ["code": code],
      ], type: "tool_execution_start")
    #expect(model.messages.first?.text == code)
    model.handleToolEvent(
      [
        "toolCallId": "code-live", "toolName": "codemode", "isError": false,
        "result": [
          "content": [
            ["type": "text", "text": "Script completed"],
            ["type": "image", "data": png, "mimeType": "image/png"],
          ]
        ],
      ], type: "tool_execution_end")
    let entry = try #require(model.messages.first)
    #expect(entry.toolInput == code)
    #expect(entry.text == "Script completed")
    #expect(entry.attachments.count == 1)
    #expect(!entry.isRunning)
  }

  @Test func scriptFailurePreservesPartialOutput() throws {
    let entry = try #require(
      AppModel.chatEntry(from: [
        "role": "toolResult", "toolCallId": "code-error", "toolName": "codemode", "isError": true,
        "content": [["type": "text", "text": "Script failed\npartial\nScript error: stopped"]],
      ]))
    #expect(entry.isError)
    #expect(entry.text.contains("partial"))
  }
}

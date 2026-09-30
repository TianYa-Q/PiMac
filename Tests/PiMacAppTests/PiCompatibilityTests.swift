import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct PiCompatibilityTests {
  @Test func handledQueuedPromptIsRemovedWithoutInventingUserMessage() {
    let app = AppModel(restoreLastProjectOnLaunch: false)
    let prompt = QueuedPrompt(
      id: UUID(), text: "/hello", rpcText: "/hello", delivery: .followUp, attachments: [])
    app.queuedPrompts = [prompt]
    app.applyPromptDisposition(["data": ["disposition": "handled"]], queuedPromptID: prompt.id)
    #expect(app.queuedPrompts.isEmpty)
    #expect(app.messages.isEmpty)
  }

  @Test func queuedAndLegacyAcceptancePreservePendingInput() {
    let app = AppModel(restoreLastProjectOnLaunch: false)
    let prompt = QueuedPrompt(
      id: UUID(), text: "hello", rpcText: "hello", delivery: .steer, attachments: [])
    let responses: [PiRPCClient.JSON] = [["disposition": "queued"], [:]]
    for data in responses {
      app.queuedPrompts = [prompt]
      app.applyPromptDisposition(["data": data], queuedPromptID: prompt.id)
      #expect(app.queuedPrompts.map(\.id) == [prompt.id])
    }
  }

  @Test func nestedCallsStayOnParentAndRestoreFromBoundedMetadata() throws {
    let app = AppModel(restoreLastProjectOnLaunch: false)
    app.handleToolEvent(
      ["toolCallId": "root", "toolName": "codemode", "args": [:]], type: "tool_execution_start")
    app.handleToolEvent(
      [
        "toolCallId": "root/1", "parentToolCallId": "root", "toolName": "read",
        "args": ["path": "file"],
      ], type: "tool_execution_start")
    app.handleToolEvent(
      [
        "toolCallId": "root/1/1", "parentToolCallId": "root/1", "toolName": "bash",
        "args": ["command": "true"],
      ], type: "tool_execution_start")
    app.handleToolEvent(
      ["toolCallId": "root/1", "parentToolCallId": "root", "toolName": "read", "isError": false],
      type: "tool_execution_end")
    #expect(app.messages.count == 1)
    #expect(app.messages[0].nestedCalls.count == 2)
    #expect(app.messages[0].nestedCalls[0].status == "ok")
    let metadata: PiRPCClient.JSON = [
      "complete": false,
      "calls": [
        [
          "id": "root/1", "name": "read", "arguments": ["path": "file"], "status": "ok",
          "durationMs": 12,
        ],
        [
          "id": "root/2", "name": "bash", "argumentsBytes": 9000, "status": "error",
          "error": "denied",
        ],
      ],
    ]
    let result: PiRPCClient.JSON = [
      "role": "toolResult", "toolCallId": "root", "toolName": "codemode", "content": [],
      "nestedCalls": metadata,
    ]
    let restored = try #require(AppModel.chatEntry(from: result))
    #expect(restored.nestedCalls.count == 2)
    #expect(restored.nestedCalls[0].durationMs == 12)
    #expect(restored.nestedCalls[1].input?.contains("9000") == true)
    #expect(!restored.nestedCallsComplete)
  }

  @Test func fastSupportsNativeResponsesButDoesNotTreatRoutersAsCodexAccounts() {
    let app = AppModel(restoreLastProjectOnLaunch: false)
    app.allModels = [
      PiModel(provider: "openai", modelId: "responses", name: "OpenAI", api: "openai-responses"),
      PiModel(provider: "openai", modelId: "chat", name: "Chat", api: "openai-completions"),
      PiModel(
        provider: "openai-codex", modelId: "native", name: "Codex", api: "openai-codex-responses"),
      PiModel(provider: "openai-codex", modelId: "auto", name: "Router", api: "pi-virtual"),
    ]
    app.selectedModelId = "openai/responses"
    #expect(app.supportsFastMode)
    #expect(!app.supportsAccountRotation)
    app.selectedModelId = "openai/chat"
    #expect(!app.supportsFastMode)
    app.selectedModelId = "openai-codex/native"
    #expect(app.supportsFastMode && app.supportsAccountRotation)
    app.selectedModelId = "openai-codex/auto"
    #expect(!app.supportsFastMode && !app.supportsAccountRotation)
  }

  @Test func unavailablePatternsAreReportedWithoutRemovingPreferences() {
    let prefs = PiModelPreferences(
      enabledModels: ["openai/*:high", "missing/model"], thinkingLevels: [:])
    let models = [PiModel(provider: "openai", modelId: "test", name: "test")]
    #expect(prefs.unmatchedPatterns(in: models) == ["missing/model"])
    #expect(prefs.enabledModels?.count == 2)
  }
}

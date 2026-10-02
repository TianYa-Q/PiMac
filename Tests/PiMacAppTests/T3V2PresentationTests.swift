import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3V2PresentationTests {
  @Test func activeRunWinsOverLaterQueuedRun() {
    let detail: [String: Any] = [
      "snapshotSequence": 42,
      "projection": [
        "thread": ["id": "thread", "title": "Title"],
        "runs": [["id": "active", "status": "waiting"], ["id": "queued", "status": "queued"]],
        "visibleTurnItems": [],
      ],
    ]
    let mapped = T3V2Presentation.detail(detail)
    let thread = mapped["thread"] as? [String: Any]
    let turn = thread?["latestTurn"] as? [String: Any]
    #expect(turn?["turnId"] as? String == "active")
    #expect(turn?["state"] as? String == "running")
    #expect(mapped["snapshotSequence"] as? Int == 42)
  }

  @Test func visibleHistoryUsesOfficialItemsIncludingInheritedReasoning() {
    let detail: [String: Any] = [
      "projection": [
        "thread": ["id": "fork"], "runs": [],
        "visibleTurnItems": [
          [
            "visibility": "inherited",
            "item": ["id": "reason", "type": "reasoning", "text": "Thinking", "streaming": false],
          ],
          [
            "visibility": "local",
            "item": ["id": "user", "type": "user_message", "text": "Hi", "attachments": []],
          ],
        ],
      ]
    ]
    let thread = T3V2Presentation.detail(detail)["thread"] as? [String: Any]
    let messages = thread?["messages"] as? [[String: Any]]
    #expect(messages?.count == 2)
    #expect(messages?.first?["role"] as? String == "reasoning")
    #expect(messages?.last?["id"] as? String == "user")
  }

  @Test func commandStringsBecomeVisibleBashInputs() throws {
    for status in ["running", "completed"] {
      for title in ["bash", "Run command"] {
        let native: [String: Any] = ["projection": [
          "thread": ["id": "thread"],
          "visibleTurnItems": [["item": [
            "id": "cmd", "type": "command_execution", "title": title,
            "status": status, "input": "printf hello", "output": "hello",
          ]]],
        ]]
        let thread = try #require(T3V2Presentation.detail(native)["thread"] as? [String: Any])
        let activities = try #require(thread["activities"] as? [[String: Any]])
        let payload = try #require(activities.first?["payload"] as? [String: Any])
        let data = try #require(payload["data"] as? [String: Any])
        #expect(data["toolName"] as? String == "bash")
        #expect(AppModel.toolInputText(toolName: "bash", args: data["input"]) == "$ printf hello")
        #expect(payload["detail"] as? String == "hello")
        #expect(payload["status"] as? String == (status == "running" ? "inProgress" : status))
      }
    }
  }

  @Test func toolParentLinksSurviveLiveAndSavedProjection() throws {
    for status in ["running", "completed"] {
      for type in ["dynamic_tool", "command_execution", "file_change"] {
        let native: [String: Any] = ["projection": [
          "thread": ["id": "thread"],
          "visibleTurnItems": [["item": [
            "id": "child", "runId": "run", "type": type,
            "status": status, "parentItemId": "code", "toolName": "read",
          ]], ["item": [
            "id": "independent", "runId": "run", "type": "dynamic_tool",
            "toolName": "read", "parentItemId": NSNull(),
          ]]],
        ]]
        let thread = try #require(T3V2Presentation.detail(native)["thread"] as? [String: Any])
        let activities = try #require(thread["activities"] as? [[String: Any]])
        let payload = try #require(activities[0]["payload"] as? [String: Any])
        let data = try #require(payload["data"] as? [String: Any])
        #expect(data["parentToolCallId"] as? String == "code")
        let independent = try #require(activities[1]["payload"] as? [String: Any])
        #expect((independent["data"] as? [String: Any])?["parentToolCallId"] == nil)
      }
    }
  }

  @Test func onlyPendingNativeRequestsBecomeDialogs() {
    let detail: [String: Any] = [
      "projection": [
        "thread": ["id": "thread"],
        "runtimeRequests": [
          ["id": "confirm", "status": "pending"], ["id": "old", "status": "resolved"],
          ["id": "input", "status": "pending"],
        ],
        "turnItems": [
          [
            "type": "approval_request", "requestId": "confirm", "title": "Allow bash?",
            "prompt": "command",
          ],
          ["type": "approval_request", "requestId": "old"],
          [
            "type": "user_input_request", "requestId": "input",
            "questions": [
              [
                "id": "q", "question": "Pick",
                "options": [["label": "Choice", "value": "native-value"]],
              ]
            ],
          ],
        ],
      ]
    ]
    let snapshot = T3V2Presentation.requests(detail)
    let requests = snapshot["requests"] as? [[String: Any]]
    #expect(requests?.count == 2)
    #expect(requests?.first?["id"] as? String == "confirm")
    #expect(requests?.last?["options"] as? [String] == ["native-value"])
  }

  @Test func pendingTurnRetainsContextAndIncludesMetricsInDetail() throws {
    let native: [String: Any] = [
      "projection": [
        "thread": ["id": "thread"],
        "providerTurns": [
          ["tokenUsage": ["usedTokens": 200, "maxTokens": 1000]],
          ["status": "running"],
        ],
      ]
    ]
    let stats = T3V2Presentation.stats(native)
    #expect(stats?.contextPercent == 20)
    #expect(stats?.contextWindow == 1000)
    #expect(stats?.outputTokensPerSecond == nil)
    let metrics = try #require(T3V2Presentation.detail(native)["sessionStats"] as? [String: Any])
    #expect(metrics["totalTokens"] as? Int == 200)
    #expect(metrics["contextWindow"] as? Int == 1000)
  }

  @Test func outputSpeedUsesRequestTimingWithoutRequiringContextUsage() {
    let usage: [String: Any] = ["outputTokens": 150, "assistantDurationMs": 3000.0]
    let native: [String: Any] = ["projection": [
      "thread": ["id": "thread"],
      "providerTurns": [["turnTokenUsage": usage]]
    ]]
    #expect(T3V2Presentation.stats(native)?.outputTokensPerSecond == 50)
    #expect(T3V2Presentation.detail(native)["sessionStats"] != nil)
  }

  @Test func newRunDoesNotReusePreviousOutputSpeed() {
    let usage: [String: Any] = ["outputTokens": 150, "assistantDurationMs": 3000.0]
    let native: [String: Any] = ["projection": [
      "runs": [["id": "new", "status": "running"]],
      "attempts": [["id": "a1", "runId": "old"], ["id": "a2", "runId": "new"]],
      "providerTurns": [
        ["runAttemptId": "a1", "tokenUsage": ["usedTokens": 200],
          "turnTokenUsage": usage],
        ["runAttemptId": "a2", "status": "running"],
      ],
    ]]
    #expect(T3V2Presentation.stats(native)?.totalTokens == 200)
    #expect(T3V2Presentation.stats(native)?.outputTokensPerSecond == nil)
  }

  @Test func missingUsageNeverInventsCostOrThroughput() {
    #expect(T3V2Presentation.stats([:]) == nil)
    let detail: [String: Any] = [
      "projection": [
        "providerTurns": [
          ["tokenUsage": ["usedTokens": 100, "maxTokens": 1000, "outputTokens": 80]]
        ]
      ]
    ]
    let stats = T3V2Presentation.stats(detail)
    #expect(stats?.contextPercent == 10)
    #expect(stats?.cost == nil)
    #expect(stats?.outputTokensPerSecond == nil)
  }
}

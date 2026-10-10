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

  @Test func compactionMapsToDedicatedCollapsibleMessage() throws {
    let native: [String: Any] = [
      "projection": [
        "thread": ["id": "thread"],
        "visibleTurnItems": [
          ["item": [
            "id": "compact", "type": "compaction", "summary": "Saved context",
            "beforeTokenCount": 256000, "afterTokenCount": 29800,
            "startedAt": "2026-01-01T00:00:01Z",
          ]],
          ["item": ["id": "unknown", "type": "compaction"]],
        ],
      ]
    ]
    let thread = try #require(T3V2Presentation.detail(native)["thread"] as? [String: Any])
    let messages = try #require(thread["messages"] as? [[String: Any]])
    #expect(messages[0]["role"] as? String == "compaction")
    #expect(messages[0]["text"] as? String == "Saved context")
    #expect((messages[0]["title"] as? String)?.contains("→") == true)
    #expect(messages[0]["createdAt"] as? String == "2026-01-01T00:00:01Z")
    #expect(messages[1]["title"] as? String == "上下文已压缩")
    #expect((thread["activities"] as? [[String: Any]])?.isEmpty == true)
  }

  @Test func commandStringsBecomeVisibleBashInputs() throws {
    for status in ["running", "completed"] {
      for title in ["bash", "Run command"] {
        let native: [String: Any] = [
          "projection": [
            "thread": ["id": "thread"],
            "visibleTurnItems": [
              [
                "item": [
                  "id": "cmd", "type": "command_execution", "title": title,
                  "status": status, "input": "printf hello", "output": "hello",
                ]
              ]
            ],
          ]
        ]
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
        let native: [String: Any] = [
          "projection": [
            "thread": ["id": "thread"],
            "visibleTurnItems": [
              [
                "item": [
                  "id": "child", "runId": "run", "type": type,
                  "status": status, "parentItemId": "code", "toolName": "read",
                ]
              ],
              [
                "item": [
                  "id": "independent", "runId": "run", "type": "dynamic_tool",
                  "toolName": "read", "parentItemId": NSNull(),
                ]
              ],
            ],
          ]
        ]
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

  @Test func officialTurnTimingAloneIsNotAAGenerationSpeed() {
    let usage: [String: Any] = ["outputTokens": 150]
    let native: [String: Any] = [
      "projection": [
        "thread": ["id": "thread"],
        "providerTurns": [
          [
            "turnTokenUsage": usage,
            "startedAt": "2026-01-01T00:00:00Z",
            "completedAt": "2026-01-01T00:00:03Z",
          ]
        ],
      ]
    ]
    #expect(T3V2Presentation.stats(native)?.outputTokensPerSecond == nil)
    #expect(T3V2Presentation.detail(native)["sessionStats"] != nil)
  }

  @Test func newRunDoesNotReusePreviousOutputSpeed() {
    let usage: [String: Any] = ["outputTokens": 150]
    let native: [String: Any] = [
      "projection": [
        "runs": [["id": "new", "status": "running"]],
        "attempts": [["id": "a1", "runId": "old"], ["id": "a2", "runId": "new"]],
        "providerTurns": [
          [
            "runAttemptId": "a1", "tokenUsage": ["usedTokens": 200],
            "turnTokenUsage": usage,
          ],
          ["runAttemptId": "a2", "status": "running"],
        ],
      ]
    ]
    #expect(T3V2Presentation.stats(native)?.totalTokens == 200)
    #expect(T3V2Presentation.stats(native)?.outputTokensPerSecond == nil)
  }

  @Test func piMetricsUseModelDurationAndNormalizedTurnCache() {
    let native: [String: Any] = ["projection": ["providerTurns": [[
      "startedAt": "2026-01-01T00:00:00Z",
      "completedAt": "2026-01-01T00:01:00Z",
      "tokenUsage": ["usedTokens": 200, "maxTokens": 1000,
                     "outputTokens": 99999, "inputTokens": 99999],
      "turnTokenUsage": ["inputTokens": 400, "outputTokens": 150,
                         "cachedInputTokens": 250, "cacheCreationTokens": 50],
      "piMetrics": ["outputDurationMs": 60000, "totalCostUsd": 0.02,
                    "speedMethod": "aa-approx-v1", "speedTokens": 100, "speedDurationMs": 2000],
    ]]]]
    let stats = T3V2Presentation.stats(native)
    #expect(stats?.outputTokensPerSecond == 50)
    #expect(stats?.inputTokens == 100)
    #expect(stats?.cacheWriteTokens == 50)
    #expect(stats?.cacheHitPercent == 62.5)
    #expect(stats?.cost == 0.02)
    #expect(stats?.contextPercent == 20)
  }

  @Test func sessionCacheAndCostAccumulateAcrossRunsWhileContextAndSpeedStayCurrent() throws {
    let native: [String: Any] = ["projection": [
      "runs": [["id": "new", "status": "running"]],
      "attempts": [["id": "a1", "runId": "old"], ["id": "a2", "runId": "new"]],
      "providerTurns": [
        ["runAttemptId": "a1",
         "turnTokenUsage": ["inputTokens": 100, "cachedInputTokens": 0],
         "piMetrics": ["totalCostUsd": 0.1]],
        ["runAttemptId": "a2",
         "tokenUsage": ["usedTokens": 200, "maxTokens": 1000],
         "turnTokenUsage": ["inputTokens": 400, "cachedInputTokens": 250,
                            "cacheCreationTokens": 50],
         "piMetrics": ["totalCostUsd": 0.2, "speedMethod": "aa-approx-v1",
                       "speedTokens": 100, "speedDurationMs": 2000]],
      ],
    ]]
    for _ in 0..<2 {
      let stats = try #require(T3V2Presentation.stats(native))
      #expect(stats.inputTokens == 200)
      #expect(stats.cacheReadTokens == 250)
      #expect(stats.cacheWriteTokens == 50)
      #expect(stats.cacheHitPercent == 50)
      #expect(abs((stats.cost ?? 0) - 0.3) < 0.000001)
      #expect(stats.totalTokens == 200)
      #expect(stats.contextPercent == 20)
      #expect(stats.outputTokensPerSecond == 50)
    }
  }

  @Test func pendingRunRetainsSessionTotalsWithoutReusingSpeedOrContextCounters() {
    let native: [String: Any] = ["projection": ["providerTurns": [
      ["turnTokenUsage": ["inputTokens": 100, "cachedInputTokens": 75],
       "piMetrics": ["totalCostUsd": 0.1, "speedMethod": "aa-approx-v1",
                     "speedTokens": 100, "speedDurationMs": 2000]],
      ["tokenUsage": ["usedTokens": 200, "maxTokens": 1000,
                      "inputTokens": 99999, "cachedInputTokens": 99999]],
      ["status": "running"],
    ]]]
    let stats = T3V2Presentation.stats(native)
    #expect(stats?.cost == 0.1)
    #expect(stats?.inputTokens == 25)
    #expect(stats?.cacheHitPercent == 75)
    #expect(stats?.contextPercent == 20)
    #expect(stats?.outputTokensPerSecond == nil)
  }

  @Test func piSpeedUpdatesBeforeRunCompletionWithoutContextUsage() {
    let native: [String: Any] = ["projection": [
      "runs": [["id": "run", "status": "running"]],
      "attempts": [["id": "attempt", "runId": "run"]],
      "providerTurns": [[
        "runAttemptId": "attempt", "status": "running", "completedAt": NSNull(),
        "turnTokenUsage": ["outputTokens": 150],
        "piMetrics": ["outputDurationMs": 60000, "speedMethod": "aa-approx-v1",
                      "speedTokens": 100, "speedDurationMs": 2000],
      ]],
    ]]
    #expect(T3V2Presentation.stats(native)?.outputTokensPerSecond == 50)
  }

  @Test func legacyAndInsufficientPiMetricsDoNotDisplayNonAASpeed() {
    for metrics: [String: Any] in [
      ["outputDurationMs": 3000],
      ["outputDurationMs": 3000, "speedMethod": "aa-approx-v1"],
      ["speedMethod": "aa-approx-v1", "speedTokens": 100, "speedDurationMs": 0],
    ] {
      let native: [String: Any] = ["projection": ["providerTurns": [[
        "turnTokenUsage": ["outputTokens": 150], "piMetrics": metrics,
      ]]]]
      #expect(T3V2Presentation.stats(native)?.outputTokensPerSecond == nil)
    }
  }

  @Test func legacyPiCumulativeUsageDoesNotBecomeTurnSpeed() {
    let native: [String: Any] = ["projection": ["providerTurns": [[
      "startedAt": "2026-01-01T00:00:00Z",
      "completedAt": "2026-01-01T00:00:03Z",
      "tokenUsage": ["usedTokens": 200, "outputTokens": 99999],
    ]]]]
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

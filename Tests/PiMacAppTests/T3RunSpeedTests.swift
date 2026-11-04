import Testing

@testable import PiMacApp

struct T3RunSpeedTests {
  @Test func retryRetainsOnlyCurrentRunSpeedUntilANewerValidSampleArrives() throws {
    let sample: [String: Any] = [
      "speedMethod": "aa-approx-v1", "speedTokens": 100, "speedDurationMs": 2000,
    ]
    var projection: [String: Any] = [
      "runs": [["id": "goal", "status": "running"]],
      "attempts": [
        ["id": "old", "runId": "previous"],
        ["id": "first", "runId": "goal"], ["id": "retry", "runId": "goal"],
      ],
      "providerTurns": [
        ["runAttemptId": "old", "turnTokenUsage": ["outputTokens": 150], "piMetrics": sample],
        ["runAttemptId": "first", "turnTokenUsage": ["outputTokens": 150], "piMetrics": sample],
        ["runAttemptId": "retry", "status": "running"],
      ],
    ]
    #expect(T3V2Presentation.stats(["projection": projection])?.outputTokensPerSecond == 50)
    var turns = try #require(projection["providerTurns"] as? [[String: Any]])
    turns[2]["piMetrics"] = ["speedMethod": "aa-approx-v1", "speedTokens": 0, "speedDurationMs": 0]
    projection["providerTurns"] = turns
    #expect(T3V2Presentation.stats(["projection": projection])?.outputTokensPerSecond == 50)
    turns[2]["piMetrics"] = [
      "speedMethod": "aa-approx-v1", "speedTokens": 180, "speedDurationMs": 2000,
    ]
    projection["providerTurns"] = turns
    #expect(T3V2Presentation.stats(["projection": projection])?.outputTokensPerSecond == 90)
    projection["runs"] = [["id": "next", "status": "running"]]
    #expect(T3V2Presentation.stats(["projection": projection])?.outputTokensPerSecond == nil)
  }

}

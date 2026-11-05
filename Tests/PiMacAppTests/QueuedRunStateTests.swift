import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct QueuedRunStateTests {
  @Test func queuedShellKeepsActivityRunningWithoutChangingLatestRunIdentity() throws {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.currentSessionPath = "t3:thread"
    model.setConversationVisible(false)
    defer { model.disconnect() }
    for status in ["preparing", "starting", "running", "waiting"] {
      let native: [String: Any] = [
        "id": "thread", "status": "queued", "latestRunId": "queued",
        "latestRunStartedAt": NSNull(), "latestRunCompletedAt": NSNull(),
        "activeRunId": "active", "activityRunStatus": status,
      ]
      let shell = T3V2Presentation.shell(["threads": [native]])
      let threads = try #require(shell["threads"] as? [[String: Any]])
      let thread = try #require(threads.first)
      #expect((thread["latestTurn"] as? [String: Any])?["turnId"] as? String == "queued")
      #expect((thread["latestTurn"] as? [String: Any])?["state"] as? String == "queued")
      #expect((thread["session"] as? [String: Any])?["status"] as? String == "running")
      #expect(
        T3V2Presentation.runningThreadIDs(threads: threads, locallyRunningIDs: []) == ["thread"])
      model.applyBackgroundThreadState(thread)
      #expect(model.isStreaming)
    }
    // 排队本身不是执行中；明确无活动 run 或旧契约缺少活动字段时均不能制造运行态。
    for activity: Any in [NSNull(), "omitted"] {
      var native: [String: Any] = [
        "id": "thread", "status": "queued", "latestRunId": "queued", "activeRunId": NSNull(),
      ]
      if activity is NSNull { native["activityRunStatus"] = activity }
      let thread = T3V2Presentation.thread(native)
      model.applyBackgroundThreadState(thread)
      #expect(!model.isStreaming)
      #expect(T3V2Presentation.runningThreadIDs(threads: [thread], locallyRunningIDs: []).isEmpty)
    }
    // 旧服务端仍按原状态工作，终止状态则清除运行提示。
    for status in ["running", "interrupted", "completed", "failed"] {
      let thread = T3V2Presentation.thread([
        "id": "thread", "status": status, "latestRunId": "last",
      ])
      model.applyBackgroundThreadState(thread)
      #expect(model.isStreaming == (status == "running"))
    }
  }
}

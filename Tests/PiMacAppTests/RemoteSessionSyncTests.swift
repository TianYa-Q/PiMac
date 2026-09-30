import Foundation
import Testing

@testable import PiMacApp

struct RemoteSessionSyncTests {
  @Test @MainActor
  func mirrorsToolsAndStatsWithoutSwitchingSessions() {
    let desktop = AppModel(restoreLastProjectOnLaunch: false)
    let remote = AppModel(restoreLastProjectOnLaunch: false)
    desktop.currentSessionPath = "/session.jsonl"
    remote.currentSessionPath = desktop.currentSessionPath
    remote.messages = [ChatEntry(id: "tool", kind: .tool, title: "bash", text: "running")]
    remote.stats = SessionStats(
      cost: 0.1, contextPercent: 12, totalTokens: 100,
      inputTokens: 80, cacheReadTokens: 20, cacheWriteTokens: 0)
    remote.isStreaming = true
    desktop.applyRemoteSessionSnapshot(from: remote)
    #expect(desktop.messages == remote.messages)
    #expect(desktop.stats?.totalTokens == 100)
    #expect(!desktop.isStreaming)
    remote.messages[0].text = "done"
    remote.stats = SessionStats(
      cost: 0.2, contextPercent: 15, totalTokens: 200,
      inputTokens: 160, cacheReadTokens: 40, cacheWriteTokens: 0)
    desktop.applyRemoteSessionSnapshot(from: remote)
    #expect(desktop.messages[0].text == "done")
    #expect(desktop.stats?.totalTokens == 200)
    desktop.applyRPCMessageSnapshot([["role": "user", "content": "stale"]])
    #expect(desktop.messages == remote.messages)
  }

  @Test @MainActor
  func doesNotOverwriteAnotherSessionOrLocalRun() {
    let desktop = AppModel(restoreLastProjectOnLaunch: false)
    let remote = AppModel(restoreLastProjectOnLaunch: false)
    desktop.currentSessionPath = "/desktop.jsonl"
    remote.currentSessionPath = "/remote.jsonl"
    remote.messages = [ChatEntry(id: "tool", kind: .tool, title: "bash", text: "done")]
    desktop.applyRemoteSessionSnapshot(from: remote)
    #expect(desktop.messages.isEmpty)
    remote.currentSessionPath = desktop.currentSessionPath
    desktop.isStreaming = true
    desktop.applyRemoteSessionSnapshot(from: remote)
    #expect(desktop.messages.isEmpty)
    desktop.isStreaming = false
    remote.projectURL = URL(fileURLWithPath: "/another-project")
    desktop.applyRemoteSessionSnapshot(from: remote)
    #expect(desktop.messages.isEmpty)
  }
}

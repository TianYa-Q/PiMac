import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct GoalResumeTests {
  @Test func runningResumeQueuesWithoutStoppingOrConsumingDraft() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/goal-resume/outbox-\(UUID())")
    let store = MessageOutboxStore(directory: root)
    let suite = "goal-resume-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let client = T3DesktopClient(defaults: defaults)
    let model = AppModel(continueLastSession: false, restoreLastProjectOnLaunch: false)
    defer {
      model.disconnect()
      client.stop()
      defaults.removePersistentDomain(forName: suite)
    }
    model.attach(
      to: client, deliveries: MessageRecoveryCoordinator(store: store, transport: client))
    client.didCompletePoll()
    model.connectionState = .connected
    model.projectURL = root
    model.selectedModelId = "test/model"
    model.currentSessionPath = "t3:running"
    model.composerText = "保留正文"
    model.attachments = [
      PromptAttachment(url: root.appendingPathComponent("draft.png"), mimeType: "image/png")
    ]
    let attachments = model.attachments.map(\.id)
    model.apply([
      "thread": [
        "id": "running", "goalDriver": "pi",
        "goal": ["objective": "完成验证", "status": "paused"],
        "latestTurn": ["turnId": "run", "state": "running"],
      ]
    ])
    #expect(model.isBusy)
    #expect(model.canResumeGoal)
    // 仅放开 resume；管理命令不能因本次调整在运行中执行。
    model.sendGoalCommand(.archive)
    #expect(store.messages.isEmpty)
    model.isCompacting = true
    #expect(!model.canResumeGoal)
    model.sendGoalCommand(.resume)
    #expect(store.messages.isEmpty)
    model.isCompacting = false
    model.isLoadingConfiguration = true
    #expect(!model.canResumeGoal)
    model.sendGoalCommand(.resume)
    #expect(store.messages.isEmpty)
    model.isLoadingConfiguration = false
    model.sendGoalCommand(.resume)
    let record = try #require(store.messages.first)
    #expect(store.messages.count == 1)
    #expect(record.threadID == "running")
    #expect(record.rpcText == "/goal resume")
    #expect(record.delivery == .followUp)
    #expect(model.isStreaming)
    #expect(!model.isStopping)
    #expect(model.composerText == "保留正文")
    #expect(model.attachments.map(\.id) == attachments)
  }

  @Test func invalidOrUnavailableGoalCannotResume() {
    let client = T3DesktopClient()
    let model = AppModel(continueLastSession: false, restoreLastProjectOnLaunch: false)
    model.attach(to: client)
    defer {
      model.disconnect()
      client.stop()
    }
    client.didCompletePoll()
    model.connectionState = .connected
    for (status, driver) in [("active", "pi"), ("complete", "pi"), ("paused", "other")] {
      model.apply([
        "thread": [
          "id": "running", "goalDriver": driver,
          "goal": ["objective": "完成验证", "status": status],
        ]
      ])
      #expect(!model.canResumeGoal)
    }
    model.apply([
      "thread": [
        "id": "running", "goalDriver": "pi",
        "goal": ["objective": "完成验证", "status": "paused"],
      ]
    ])
    model.connectionState = .disconnected
    #expect(!model.canResumeGoal)
  }
}

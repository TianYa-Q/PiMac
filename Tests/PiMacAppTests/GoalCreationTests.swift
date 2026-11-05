import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct GoalCreationTests {
  @Test func startAndCancelUseOneNativeRouteWithoutConsumingDraft() {
    var submissions: [String] = []
    var dismissed = 0
    #expect(
      GoalCreationAction.start.perform(
        objective: "  导出 CSV  ", unavailableReason: nil, onDismiss: { dismissed += 1 },
        onStart: {
          submissions.append($0)
          return true
        }))
    #expect(submissions == ["导出 CSV"])
    #expect(dismissed == 1)
    #expect(
      GoalCreationAction.cancel.perform(
        objective: "", unavailableReason: "忙碌", onDismiss: { dismissed += 1 },
        onStart: { _ in
          Issue.record("取消不能提交")
          return false
        }))
    #expect(dismissed == 2)
  }

  @Test func invalidBusyAndRejectedActionsKeepForm() {
    for (text, reason) in [(" \n ", nil), (String(repeating: "x", count: 4001), nil), ("导出", "忙碌")]
    {
      var dismissed = false
      #expect(
        !GoalCreationAction.start.perform(
          objective: text, unavailableReason: reason, onDismiss: { dismissed = true },
          onStart: { _ in
            Issue.record("非法提交")
            return true
          }))
      #expect(!dismissed)
    }
    var dismissed = false
    #expect(
      !GoalCreationAction.start.perform(
        objective: "导出", unavailableReason: nil, onDismiss: { dismissed = true },
        onStart: { _ in false }))
    #expect(!dismissed)
  }

  @Test func runningCreationPersistsQueuedGoalWithoutStoppingOrConsumingDraft() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/running-goal/outbox-\(UUID())")
    let store = MessageOutboxStore(directory: root)
    let suite = "running-goal-\(UUID())"
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
        "latestTurn": ["turnId": "run", "state": "running"],
      ]
    ])
    #expect(model.isBusy)
    #expect(model.goalCreationUnavailableReason == nil)
    #expect(model.startGoal(objective: "  完成导出并验证  "))
    let record = try #require(store.messages.first)
    #expect(record.threadID == "running")
    #expect(record.rpcText == "/goal 完成导出并验证")
    #expect(record.delivery == .followUp)
    #expect(model.isStreaming)
    #expect(!model.isStopping)
    #expect(model.composerText == "保留正文")
    #expect(model.attachments.map(\.id) == attachments)
  }

  @Test func configurationLoadingAndCompactionStillBlockGoalCreation() {
    let client = T3DesktopClient()
    let model = AppModel(continueLastSession: false, restoreLastProjectOnLaunch: false)
    model.attach(to: client)
    defer {
      model.disconnect()
      client.stop()
    }
    client.didCompletePoll()
    model.connectionState = .connected
    model.projectURL = URL(fileURLWithPath: "/tmp/pimac-ui-fixture")
    model.selectedModelId = "test/model"
    #expect(model.goalCreationUnavailableReason == nil)
    model.isLoadingConfiguration = true
    #expect(model.goalCreationUnavailableReason != nil)
    #expect(!model.startGoal(objective: "不能提交"))
    model.isLoadingConfiguration = false
    model.isCompacting = true
    #expect(model.goalCreationUnavailableReason != nil)
    #expect(!model.startGoal(objective: "不能提交"))
  }

  @Test func disconnectedEntryPreservesDraft() {
    let model = AppModel(continueLastSession: false, restoreLastProjectOnLaunch: false)
    model.composerText = "未发送正文"
    #expect(!model.startGoal(objective: "导出 CSV"))
    #expect(model.messages.isEmpty)
    #expect(model.composerText == "未发送正文")
  }
}

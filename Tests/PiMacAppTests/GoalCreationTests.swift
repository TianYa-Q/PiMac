import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct GoalCreationTests {
  @Test func commandsKeepGoalTextAndRejectEmptyInput() {
    #expect(GoalStartMode.discuss.command(objective: "  导出 CSV\n保留筛选  ") == "/goal 导出 CSV\n保留筛选")
    #expect(GoalStartMode.direct.command(objective: "  导出 CSV  ") == "/goal-direct 导出 CSV")
    for mode in GoalStartMode.allCases {
      #expect(mode.command(objective: " \n\t ") == nil)
    }
  }

  @Test func formActionsRouteBothModesAndCancelNeverSubmits() {
    for action in [GoalCreationAction.start(.discuss), .start(.direct), .cancel] {
      var submitted: [(String, GoalStartMode)] = []
      var dismissed = 0
      #expect(
        action.perform(
          objective: "导出 CSV", unavailableReason: nil,
          onDismiss: { dismissed += 1 },
          onStart: { text, mode in
            submitted.append((text, mode))
            return true
          }))
      #expect(dismissed == 1)
      switch action {
      case .cancel:
        #expect(submitted.isEmpty)
      case .start(let mode):
        #expect(submitted.count == 1)
        #expect(submitted.first?.0 == "导出 CSV")
        #expect(submitted.first?.1 == mode)
      }
    }
  }

  @Test func emptyBusyAndRejectedActionsKeepDialogWithoutDispatching() {
    for mode in GoalStartMode.allCases {
      for (text, reason) in [(" \n ", nil), ("导出 CSV", "会话正在执行")] {
        var sends = 0
        var dismissed = 0
        #expect(
          !GoalCreationAction.start(mode).perform(
            objective: text, unavailableReason: reason, onDismiss: { dismissed += 1 },
            onStart: { _, _ in
              sends += 1
              return true
            }))
        #expect(sends == 0)
        #expect(dismissed == 0)
      }
      var dismissed = 0
      var attempts = 0
      #expect(
        !GoalCreationAction.start(mode).perform(
          objective: "导出 CSV", unavailableReason: nil, onDismiss: { dismissed += 1 },
          onStart: { _, _ in
            attempts += 1
            return false
          }))
      #expect(attempts == 1)
      #expect(dismissed == 0)
    }
    var dismissed = 0
    #expect(
      GoalCreationAction.cancel.perform(
        objective: "", unavailableReason: "会话正在执行", onDismiss: { dismissed += 1 },
        onStart: { _, _ in
          Issue.record("取消不应提交目标")
          return false
        }))
    #expect(dismissed == 1)
  }

  @Test func disconnectedEntryRejectsStartWithoutChangingDraft() {
    let model = AppModel(continueLastSession: false, restoreLastProjectOnLaunch: false)
    model.composerText = "未发送正文"
    model.attachments = [
      PromptAttachment(url: URL(fileURLWithPath: "/tmp/unsent-goal.png"), mimeType: "image/png")
    ]
    let attachmentIDs = model.attachments.map(\.id)
    #expect(model.goalState == .none)
    #expect(model.goalCreationUnavailableReason != nil)
    #expect(!model.startGoal(objective: "导出 CSV", mode: .discuss))
    model.isStreaming = true
    #expect(model.goalCreationUnavailableReason?.contains("正在执行") == true)
    #expect(!model.startGoal(objective: "导出 CSV", mode: .direct))
    #expect(model.messages.isEmpty)
    #expect(model.composerText == "未发送正文")
    #expect(model.attachments.map(\.id) == attachmentIDs)
  }

}

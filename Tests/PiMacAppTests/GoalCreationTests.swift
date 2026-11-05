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

  @Test func disconnectedEntryPreservesDraft() {
    let model = AppModel(continueLastSession: false, restoreLastProjectOnLaunch: false)
    model.composerText = "未发送正文"
    #expect(!model.startGoal(objective: "导出 CSV"))
    #expect(model.messages.isEmpty)
    #expect(model.composerText == "未发送正文")
  }
}

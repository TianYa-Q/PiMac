import SwiftUI

struct GoalRevisionForm: View {
  let revision: GoalRevision
  let state: ThreadGoal.State
  let canControl: Bool
  let onDismiss: () -> Void
  let onRevise: (GoalRevision, String) -> Bool
  @State private var objective: String
  @State private var submissionRejected = false
  @FocusState private var isFocused: Bool

  init(
    revision: GoalRevision, state: ThreadGoal.State, canControl: Bool,
    onDismiss: @escaping () -> Void, onRevise: @escaping (GoalRevision, String) -> Bool
  ) {
    self.revision = revision
    self.state = state
    self.canControl = canControl
    self.onDismiss = onDismiss
    self.onRevise = onRevise
    _objective = State(initialValue: revision.original.objective)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("编辑目标").font(.headline)
      Text("修改完整目标内容，包括需要保留的要求和验收标准。")
        .font(.subheadline)
      TextEditor(text: $objective)
        .font(.body)
        .focused($isFocused)
        .accessibilityLabel("目标内容")
        .frame(height: 200)
        .padding(6)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))
      Text("提交后先讨论并确认修订，不会直接覆盖已保存的目标。取消此窗口不会修改目标。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      // 固定反馈区高度，忙碌或拒绝提交时不挤动编辑器和按钮。
      Text(
        !canControl
          ? "会话暂不可操作，请完成当前执行或交互后再提交。" : submissionRejected ? "修订未提交，目标可能已变化；请检查会话状态后重试。" : " "
      )
      .font(.caption)
      .foregroundStyle(.orange)
      .frame(height: 30, alignment: .topLeading)
      HStack {
        Button("取消", action: onDismiss).keyboardShortcut(.cancelAction)
        Spacer()
        Button("讨论并确认修改") {
          guard canControl, revision.command(objective: objective, state: state) != nil else {
            return
          }
          if onRevise(revision, objective) {
            onDismiss()
          } else {
            submissionRejected = true
          }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!canControl || revision.command(objective: objective, state: state) == nil)
      }
    }
    .padding(20)
    .frame(width: 540)
    .onAppear { isFocused = true }
  }
}

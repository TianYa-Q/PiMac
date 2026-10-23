import SwiftUI

struct ThreadGoalView: View {
  let state: ThreadGoal.State
  let canControl: Bool
  let onCommand: (String) -> Void

  var body: some View {
    switch state {
    case .none:
      EmptyView()
    case .invalid:
      Label("Goal 状态数据异常，请刷新会话", systemImage: "exclamationmark.triangle")
        .font(.system(size: 12))
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .available(let goal, let driver):
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 7) {
          Label("Goal", systemImage: "target")
            .fontWeight(.semibold)
          Text(goal.status.title)
            .foregroundStyle(goal.status == .active ? Color.accentColor : .secondary)
          Spacer(minLength: 0)
          if driver == "pi" {
            Button("详情") { onCommand("/goal-status") }
            if goal.status == .active {
              Button("暂停") { onCommand("/goal-pause") }
            } else if goal.status != .complete {
              Button("恢复") { onCommand("/goal-resume") }
            }
            Menu {
              Button("切换目标…") { onCommand("/goal-focus") }
              Button("目标设置…") { onCommand("/goal-settings") }
              Button("归档目标…") { onCommand("/goal-clear") }
            } label: {
              Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
          }
        }
        .buttonStyle(.borderless)
        .disabled(!canControl)
        .help(canControl ? "调用 pi-goal-x 原生命令" : "执行中可使用输入框右下角的停止按钮；其他操作需等待空闲")
        Text(goal.objective)
          .lineLimit(3)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .help(goal.objective)
        if goal.tokensUsed != nil || goal.timeUsedSeconds != nil {
          HStack(spacing: 12) {
            if let tokens = goal.tokensUsed {
              Text("\(tokens.formatted()) tokens")
            }
            if let seconds = goal.timeUsedSeconds {
              Text("\(seconds / 60) 分 \(seconds % 60) 秒")
            }
          }
          .foregroundStyle(.secondary)
          .monospacedDigit()
        }
      }
      .font(.system(size: 12))
      .padding(10)
      .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
  }
}

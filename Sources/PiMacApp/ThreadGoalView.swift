import SwiftUI

struct GoalObjectiveText: View {
  let objective: String
  let expanded: Bool

  var body: some View {
    Text(objective)
      .lineLimit(expanded ? nil : 3)
      .textSelection(.enabled)
      // 输入区会压缩可变高度文本；取消行数限制还不够，需按实际换行高度布局。
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct ThreadGoalView: View {
  let state: ThreadGoal.State
  let canControl: Bool
  let canPause: Bool
  let canResume: Bool
  let onCommand: (GoalCommand) -> Void
  let onRevise: (GoalRevision, String) -> Bool
  let onStart: (String) -> Bool
  @State private var editor: Editor?
  @State private var expanded = false
  @State private var newObjective = ""

  private enum Editor: String, Identifiable {
    case create, revise
    var id: String { rawValue }
  }

  var body: some View {
    switch state {
    case .none:
      EmptyView()
    case .invalid:
      Label("目标状态数据异常，请刷新会话", systemImage: "exclamationmark.triangle")
        .font(.system(size: 12))
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .available(let goal, let driver):
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Label("当前目标", systemImage: "target")
            .fontWeight(.semibold)
          Text(goal.status.title)
            .foregroundStyle(
              goal.status == .blocked
                ? Color.orange
                : goal.status == .active ? Color.accentColor : .secondary)
          Spacer(minLength: 0)
          if driver == "pi" {
            if goal.status != .complete {
              Button("编辑目标") { editor = .revise }
                .disabled(!canControl)
              Button(goal.status == .active ? "暂停执行" : "继续执行") {
                onCommand(goal.status == .active ? .pause : .resume)
              }
              .disabled(goal.status == .active ? !canPause : !canResume)
            }
            Menu {
              Button("查看进度…") { onCommand(.progress) }
              Button("新建目标…") {
                newObjective = ""
                editor = .create
              }
              Divider()
              Button("清除当前目标") { onCommand(.archive) }
            } label: {
              Image(systemName: "ellipsis")
            }
            .disabled(!canControl)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("目标管理")
          }
        }
        .buttonStyle(.borderless)
        .help("运行中可暂停，继续执行将排队到当前任务结束后；编辑和目标管理需等待会话空闲")
        if let reason = goal.blockerDescription {
          VStack(alignment: .leading, spacing: 4) {
            Label("阻塞原因与所需协助", systemImage: "exclamationmark.triangle")
              .fontWeight(.medium)
              .foregroundStyle(.orange)
            Text(reason)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityElement(children: .combine)
        }
        GoalObjectiveText(objective: goal.objective, expanded: expanded)
        HStack(spacing: 12) {
          Button(expanded ? "收起正文" : "展开正文") { expanded.toggle() }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
          Spacer(minLength: 0)
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
      .font(.system(size: 12))
      .padding(12)
      .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
      .sheet(item: $editor) { mode in
        switch mode {
        case .create:
          GoalCreationForm(
            objective: $newObjective,
            unavailableReason: canControl ? nil : "会话暂不可操作，请空闲后再创建目标",
            onDismiss: { editor = nil }, onStart: onStart)
        case .revise:
          GoalRevisionForm(
            revision: GoalRevision(original: goal), state: state, canControl: canControl,
            onDismiss: { editor = nil }, onRevise: onRevise)
        }
      }
      // 不因 token、计时或暂时忙碌关闭编辑器；仅目标上下文失效时关闭，避免跨目标提交。
      .onChange(of: goal.objective) { _, _ in
        editor = nil
        expanded = false
      }
      .onChange(of: driver) { _, _ in editor = nil }
      .onChange(of: goal.status) { _, status in
        if status == .complete { editor = nil }
      }
    }
  }
}

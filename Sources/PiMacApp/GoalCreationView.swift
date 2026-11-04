import SwiftUI

enum GoalStartMode: CaseIterable {
  case discuss
  case direct

  func command(objective: String) -> String? {
    let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return "\(self == .discuss ? "/goal" : "/goal-direct") \(text)"
  }
}

/// 统一处理弹窗动作：取消不走提交回调，拒绝提交时保留弹窗和用户输入。
enum GoalCreationAction {
  case cancel
  case start(GoalStartMode)

  @discardableResult
  func perform(
    objective: String, unavailableReason: String?, onDismiss: () -> Void,
    onStart: (String, GoalStartMode) -> Bool
  ) -> Bool {
    if case .start(let mode) = self {
      guard unavailableReason == nil, mode.command(objective: objective) != nil,
        onStart(objective, mode)
      else { return false }
    }
    onDismiss()
    return true
  }
}

/// 输入只属于当前弹窗；不复用 composer，取消或发送都不改动正文和附件。
struct GoalCreationButton: View {
  let state: ThreadGoal.State
  let unavailableReason: String?
  let onStart: (String, GoalStartMode) -> Bool
  let onCommand: (GoalCommand) -> Void
  @State private var isPresented = false
  @State private var objective = ""

  var body: some View {
    Menu {
      Button("新建目标…") {
        objective = ""
        isPresented = true
      }
      Button("选择已有目标…") { onCommand(.focus) }
        .disabled(!GoalCommand.focus.isAvailable(in: state))
      Divider()
      Button("运行与审核设置（高级）…") { onCommand(.settings) }
        .disabled(!GoalCommand.settings.isAvailable(in: state))
    } label: {
      Label("目标", systemImage: "target")
        .font(.system(size: 12, weight: .medium))
    }
    // Menu 不是普通 Button；显式使用紧凑菜单样式并锁定理想尺寸，避免原生弹出控件横向吃满 HStack。
    .menuStyle(.borderlessButton)
    .fixedSize()
    .controlSize(.small)
    .disabled(unavailableReason != nil)
    .help(unavailableReason ?? "新建目标，或选择已有目标")
    .accessibilityLabel("目标管理")
    .sheet(isPresented: $isPresented) {
      GoalCreationForm(
        objective: $objective, unavailableReason: unavailableReason,
        onDismiss: { isPresented = false }, onStart: onStart)
    }
  }
}

struct GoalCreationForm: View {
  @Binding var objective: String
  let unavailableReason: String?
  let onDismiss: () -> Void
  let onStart: (String, GoalStartMode) -> Bool
  @State private var submissionRejected = false
  @FocusState private var isFocused: Bool

  private var canStart: Bool {
    unavailableReason == nil && GoalStartMode.discuss.command(objective: objective) != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("新建目标", systemImage: "target")
        .font(.headline)
      Text("描述你希望完成的目标")
        .font(.subheadline)
      TextEditor(text: $objective)
        .font(.body)
        .focused($isFocused)
        .accessibilityLabel("目标描述")
        .frame(height: 100)
        .padding(6)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))
      Text("讨论并确认：先明确目标、计划和验收标准，确认后执行。\n直接开始：跳过确认，立即按描述创建并执行目标。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text(unavailableReason ?? (submissionRejected ? "目标未提交，请检查会话状态后重试。" : " "))
        .font(.caption)
        .foregroundStyle(.orange)
        .frame(height: 30, alignment: .topLeading)
      HStack {
        Button("取消") { perform(.cancel) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("直接开始") { perform(.start(.direct)) }
          .disabled(!canStart)
        Button("讨论并确认") { perform(.start(.discuss)) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!canStart)
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear { isFocused = true }
  }

  private func perform(_ action: GoalCreationAction) {
    submissionRejected = !action.perform(
      objective: objective, unavailableReason: unavailableReason,
      onDismiss: onDismiss, onStart: onStart)
  }
}

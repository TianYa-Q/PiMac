import SwiftUI

/// 统一处理弹窗动作：取消不提交，拒绝提交时保留用户输入。
enum GoalCreationAction {
  case cancel, start

  @discardableResult
  func perform(
    objective: String, unavailableReason: String?, onDismiss: () -> Void,
    onStart: (String) -> Bool
  ) -> Bool {
    if case .start = self {
      let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
      guard unavailableReason == nil, !text.isEmpty, text.utf16.count <= 4000, onStart(text)
      else { return false }
    }
    onDismiss()
    return true
  }
}

struct GoalCreationButton: View {
  let unavailableReason: String?
  let onStart: (String) -> Bool
  @State private var isPresented = false
  @State private var objective = ""

  var body: some View {
    Button {
      objective = ""
      isPresented = true
    } label: {
      Label("目标", systemImage: "target")
        .font(.system(size: 12, weight: .medium))
    }
    .buttonStyle(.borderless)
    .fixedSize()
    .controlSize(.small)
    .disabled(unavailableReason != nil)
    .help(unavailableReason ?? "新建当前会话的目标")
    .accessibilityLabel("新建目标")
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
  let onStart: (String) -> Bool
  @State private var submissionRejected = false
  @FocusState private var isFocused: Bool

  private var canStart: Bool {
    let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
    return unavailableReason == nil && !text.isEmpty && text.utf16.count <= 4000
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("新建目标", systemImage: "target").font(.headline)
      Text("描述你希望完成的目标").font(.subheadline)
      TextEditor(text: $objective)
        .font(.body)
        .focused($isFocused)
        .accessibilityLabel("目标描述")
        .frame(height: 100)
        .padding(6)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))
      Text("每个会话保留一个目标，开始后立即执行。默认每 25 次自动响应暂停，供你检查进度。目标最多 4000 字符。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text(unavailableReason ?? (submissionRejected ? "目标未提交，请检查会话状态后重试。" : " "))
        .font(.caption)
        .foregroundStyle(.orange)
        .frame(height: 30, alignment: .topLeading)
      HStack {
        Button("取消") { perform(.cancel) }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("开始执行") { perform(.start) }
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

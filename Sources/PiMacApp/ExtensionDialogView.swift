import SwiftUI

/// Each instance belongs to one local presentation, never to a reused RPC ID.
struct ExtensionDialogView: View {
  @EnvironmentObject private var extensionUI: ExtensionUIModel
  let dialog: ExtensionDialog
  @State private var text = ""
  @State private var query = ""
  @State private var confirmingDiscard = false
  @FocusState private var inputFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Label(extensionUI.dialogSourceLabel, systemImage: "bubble.left.and.bubble.right")
          .lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 8)
        if extensionUI.pendingDialogCount > 1 {
          Text("另有 \(extensionUI.pendingDialogCount - 1) 条待处理")
            .fixedSize()
        }
      }
      .font(.caption).foregroundStyle(.secondary)
      .padding(.horizontal, 24).padding(.top, 16)
      if let presentation = AccountManagementPresentation(dialog: dialog) {
        AccountManagementDialogView(presentation: presentation) { answer(value: $0) }
      } else if let presentation = AccountVisibilityPresentation(dialog: dialog) {
        AccountVisibilityDialogView(
          presentation: presentation,
          answer: { answer(value: $0) }, cancel: { answer(cancelled: true) })
      } else {
        standardDialog
      }
    }
    .confirmationDialog("放弃尚未提交的修改？", isPresented: $confirmingDiscard) {
      Button("放弃修改", role: .destructive) { answer(cancelled: true) }
      Button("继续编辑", role: .cancel) {}
    }
    .onAppear {
      if case .input(let initialText, _, _) = dialog.kind {
        text = initialText
        inputFocused = true
      }
    }
  }

  private var standardDialog: some View {
    VStack(alignment: .leading, spacing: 16) {
      ViewThatFits(in: .vertical) {
        Text(dialog.title).font(.headline)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
        ScrollView {
          Text(dialog.title).font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(height: 100)
      }
      .frame(maxHeight: 100, alignment: .leading)
      switch dialog.kind {
      case .select(let options):
        let filtered = ExtensionOptionSearch.filter(options, query: query)
        if options.count > 8 {
          HStack {
            TextField("搜索选项", text: $query)
              .textFieldStyle(.roundedBorder)
              .accessibilityLabel("搜索扩展选项")
              .onSubmit {
                if filtered.count == 1 { answer(value: filtered[0].value) }
              }
            Text("\(filtered.count)/\(options.count)")
              .font(.caption).foregroundStyle(.secondary).monospacedDigit()
          }
        }
        ScrollView {
          LazyVStack(spacing: 8) {
            if filtered.isEmpty {
              Text(options.isEmpty ? "没有可选项" : "没有匹配的选项")
                .foregroundStyle(.secondary).padding(24)
            }
            ForEach(filtered) { option in
              Button {
                answer(value: option.value)
              } label: {
                HStack {
                  Text(option.value).multilineTextAlignment(.leading)
                  Spacer()
                  Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
        .frame(maxHeight: 320)
        Divider()
        HStack {
          Spacer()
          Button("取消") { answer(cancelled: true) }.keyboardShortcut(.cancelAction)
        }
      case .confirm(let message):
        ScrollView {
          Text(message).frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 260)
        HStack {
          Spacer()
          Button("取消") { answer(confirmed: false) }.keyboardShortcut(.cancelAction)
          // No Return shortcut: confirmation may authorize a destructive action.
          Button("确认") { answer(confirmed: true) }.buttonStyle(.borderedProminent)
        }
      case .input(_, let placeholder, let multiline):
        if multiline {
          TextEditor(text: $text).focused($inputFocused).frame(height: 200)
            .accessibilityLabel(placeholder.isEmpty ? dialog.title : placeholder)
        } else {
          TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
            .focused($inputFocused).onSubmit { submitInput() }
        }
        HStack {
          Text("\(text.utf8.count) / \(ExtensionDialogLimits.maximumBytes) 字节")
            .font(.caption).monospacedDigit()
            .foregroundStyle(ExtensionDialogLimits.acceptsInput(text) ? Color.secondary : Color.red)
          Spacer()
          Button("取消") { cancelInput() }.keyboardShortcut(.cancelAction)
          Button("提交") { submitInput() }.buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .help("提交输入（⌘Return）")
            .disabled(!ExtensionDialogLimits.acceptsInput(text))
        }
      }
    }
    .padding(24).frame(width: 480)
  }

  private func submitInput() {
    guard ExtensionDialogLimits.acceptsInput(text) else { return }
    answer(value: text)
  }

  private func cancelInput() {
    if case .input(let initial, _, _) = dialog.kind, text != initial {
      confirmingDiscard = true
    } else {
      answer(cancelled: true)
    }
  }

  private func answer(value: String? = nil, confirmed: Bool? = nil, cancelled: Bool = false) {
    extensionUI.answerDialog(
      presentationID: dialog.presentationID, value: value, confirmed: confirmed,
      cancelled: cancelled)
  }
}

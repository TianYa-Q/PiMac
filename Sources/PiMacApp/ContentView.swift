import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var workspace: WorkspaceModel
  @State private var choosingProject = false
  @State private var choosingSession = false
  @State private var showingSettings = false
  @State private var sessionNameDraft = ""
  @State private var diagnosticsExpanded = false
  @State private var composerFocused = false

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
    } detail: {
      VStack(spacing: 0) {
        conversation
        Divider()
        composer
      }
      .frame(minWidth: 680, minHeight: 560)
    }
    .fileImporter(isPresented: $choosingProject, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result { workspace.replaceProject(with: url) }
    }
    .fileImporter(isPresented: $choosingSession, allowedContentTypes: [.json, .data]) { result in
      guard case .success(let url) = result, let projectURL = app.projectURL else { return }
      workspace.openSession(path: url.path, in: projectURL)
    }
    .sheet(isPresented: $showingSettings) {
      SettingsView(path: app.piPath) { app.piPath = $0 }
    }
    .sheet(item: $app.extensionDialog) { dialog in
      ExtensionDialogView(dialog: dialog)
        .environmentObject(app)
    }
    .onChange(of: app.connectionState) {
      if case .connected = app.connectionState {
        composerFocused = true
      }
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Pi Mac", systemImage: "apple.terminal")
        .font(.title2.bold())

      HStack(spacing: 7) {
        Circle().fill(app.connectionState.color).frame(width: 8, height: 8)
        Text(app.connectionState.label).font(.caption)
      }

      GroupBox("工作目录") {
        VStack(alignment: .leading, spacing: 8) {
          Text(app.projectURL?.path ?? "尚未选择项目")
            .font(.caption.monospaced())
            .lineLimit(4)
            .textSelection(.enabled)
          Button("选择并连接…", systemImage: "folder") { choosingProject = true }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      if case .connected = app.connectionState {
        GroupBox("会话") {
          VStack(alignment: .leading, spacing: 9) {
            TextField("会话名称", text: $sessionNameDraft)
              .onSubmit {
                app.sessionName = sessionNameDraft
                app.setSessionName(sessionNameDraft)
              }
              .onAppear { sessionNameDraft = app.sessionName }
              .onChange(of: app.sessionName) { _, name in sessionNameDraft = name }
            HStack {
              Button("新会话", systemImage: "plus.bubble") {
                guard let projectURL = app.projectURL else { return }
                workspace.newSession(in: projectURL)
              }
              .help("在当前窗口创建并切换到新会话；其他任务继续在后台运行")
              Button("打开…", systemImage: "folder") { choosingSession = true }
            }
            Button("压缩上下文", systemImage: "arrow.down.right.and.arrow.up.left", action: app.compact)

            Divider()
            Text("历史会话").font(.caption.bold()).foregroundStyle(.secondary)
            if app.sessions.isEmpty {
              Text("当前项目暂无历史会话")
                .font(.caption)
                .foregroundStyle(.tertiary)
            } else {
              ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                  ForEach(app.sessions) { session in
                    Button {
                      guard let projectURL = app.projectURL else { return }
                      workspace.openSession(path: session.path, in: projectURL)
                    } label: {
                      HStack(spacing: 7) {
                        Image(
                          systemName: session.path == app.currentSessionPath
                            ? "bubble.left.fill" : "bubble.left"
                        )
                        .foregroundStyle(
                          session.path == app.currentSessionPath
                            ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                          Text(session.title)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                          Text(session.modifiedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        if workspace.model(forSessionPath: session.path)?.isStreaming == true {
                          ProgressView().controlSize(.mini)
                        }
                      }
                      .contentShape(Rectangle())
                      .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                  }
                }
              }
              .frame(maxHeight: 230)
            }
          }
          .buttonStyle(.plain)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      if !app.diagnosticText.isEmpty {
        DisclosureGroup("诊断日志", isExpanded: $diagnosticsExpanded) {
          VStack(alignment: .leading, spacing: 6) {
            ScrollView {
              Text(app.diagnosticText)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            Button("复制日志") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(app.diagnosticText, forType: .string)
            }
            .font(.caption)
          }
          .padding(.top, 5)
        }
        .font(.caption)
      }

      Spacer()

      CodexAccountsView()
        .environmentObject(app)

      if let stats = app.stats {
        VStack(alignment: .leading, spacing: 4) {
          Text("\(stats.totalTokens.formatted()) tokens")
          Text(stats.contextPercent.map { "上下文 \(Int($0))%" } ?? "上下文统计等待更新")
          Text(stats.cost, format: .currency(code: "USD"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Button("设置", systemImage: "gearshape") { showingSettings = true }
        .buttonStyle(.plain)
    }
    .padding()
  }

  private var conversation: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          if app.messages.isEmpty {
            ContentUnavailableView(
              "开始和 Pi 对话",
              systemImage: "bubble.left.and.bubble.right",
              description: Text("Pi 可以读取、编辑文件并执行项目命令。")
            )
            .frame(maxWidth: .infinity, minHeight: 360)
          }
          ForEach(app.messages) { entry in
            ChatEntryView(entry: entry).id(entry.id)
          }
        }
        .padding(20)
      }
      .onChange(of: app.messages.count) {
        if let id = app.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
      }
      .onChange(of: app.messages.last?.text) {
        if let id = app.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
      }
    }
  }

  private var composer: some View {
    VStack(spacing: 8) {
      ZStack(alignment: .topLeading) {
        ComposerTextView(
          text: $app.composerText,
          isFocused: $composerFocused,
          onSubmit: app.sendPrompt
        )
        .frame(minHeight: 72, maxHeight: 150)
        if app.composerText.isEmpty {
          Text("给 Pi 发送消息…")
            .foregroundStyle(.tertiary)
            .padding(.leading, 9)
            .padding(.top, 9)
            .allowsHitTesting(false)
        }
      }

      HStack(spacing: 8) {
        modelMenu
        thinkingMenu
        Spacer()
        if !app.statusText.isEmpty {
          ProgressView().controlSize(.small)
          Text(app.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if app.isStreaming {
          Button(action: app.abort) {
            Image(systemName: "stop.fill")
              .font(.caption.bold())
              .frame(width: 26, height: 26)
          }
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .clipShape(Circle())
          .help("停止当前任务")
        } else {
          Button(action: app.sendPrompt) {
            Image(systemName: "arrow.up")
              .font(.body.bold())
              .frame(width: 26, height: 26)
          }
          .buttonStyle(.borderedProminent)
          .clipShape(Circle())
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(
            app.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || !app.clientConnected
          )
          .help("发送（Enter）")
        }
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 14))
    .padding(12)
  }

  private var modelMenu: some View {
    Menu {
      ForEach(app.models) { model in
        Button {
          app.changeModel(to: model.id)
        } label: {
          if model.id == app.selectedModelId {
            Label("\(model.name) · \(model.provider)", systemImage: "checkmark")
          } else {
            Text("\(model.name) · \(model.provider)")
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "sparkles")
        Text(app.models.first(where: { $0.id == app.selectedModelId })?.name ?? "选择模型")
          .lineLimit(1)
        Image(systemName: "chevron.down").font(.caption2)
      }
      .font(.caption)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(app.isStreaming || app.models.isEmpty)
  }

  private var thinkingMenu: some View {
    Menu {
      ForEach(app.thinkingLevels, id: \.self) { level in
        Button {
          app.changeThinkingLevel(to: level)
        } label: {
          if level == app.selectedThinkingLevel {
            Label(thinkingLabel(level), systemImage: "checkmark")
          } else {
            Text(thinkingLabel(level))
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "brain.head.profile")
        Text(thinkingLabel(app.selectedThinkingLevel))
        Image(systemName: "chevron.down").font(.caption2)
      }
      .font(.caption)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(app.isStreaming)
  }

  private func thinkingLabel(_ level: String) -> String {
    switch level {
    case "off": "不思考"
    case "minimal": "最简思考"
    case "low": "低思考"
    case "medium": "中等思考"
    case "high": "高思考"
    case "xhigh": "超高思考"
    case "max": "最大思考"
    default: level
    }
  }
}

private struct ComposerTextView: NSViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  let onSubmit: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, isFocused: $isFocused)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    let textView = SubmitTextView()
    textView.delegate = context.coordinator
    textView.onSubmit = onSubmit
    textView.isRichText = false
    textView.importsGraphics = false
    textView.drawsBackground = false
    textView.allowsUndo = true
    textView.font = .systemFont(ofSize: NSFont.systemFontSize)
    textView.textContainerInset = NSSize(width: 5, height: 6)
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )
    scrollView.documentView = textView
    context.coordinator.textView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? SubmitTextView else { return }
    textView.onSubmit = onSubmit
    if textView.string != text {
      textView.string = text
      textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
    }
    if isFocused, textView.window?.firstResponder !== textView {
      DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String
    @Binding var isFocused: Bool
    weak var textView: NSTextView?

    init(text: Binding<String>, isFocused: Binding<Bool>) {
      _text = text
      _isFocused = isFocused
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text = textView.string
    }

    func textDidBeginEditing(_ notification: Notification) {
      isFocused = true
    }

    func textDidEndEditing(_ notification: Notification) {
      isFocused = false
    }
  }

  final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
      let isReturn = event.keyCode == 36 || event.keyCode == 76
      guard isReturn else {
        super.keyDown(with: event)
        return
      }

      // 输入法有未确认文本时，Enter 必须先交给 NSTextInputContext 选词。
      if hasMarkedText() {
        super.keyDown(with: event)
        return
      }
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      if modifiers.contains(.shift) {
        insertNewlineIgnoringFieldEditor(nil)
        return
      }
      onSubmit?()
    }
  }
}

private struct ChatEntryView: View {
  let entry: ChatEntry
  @State private var expanded: Bool

  init(entry: ChatEntry) {
    self.entry = entry
    _expanded = State(initialValue: entry.kind != .thinking && entry.kind != .tool)
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .foregroundStyle(color)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(entry.title).font(.caption.bold()).foregroundStyle(.secondary)
          if entry.isRunning { ProgressView().controlSize(.mini) }
        }
        if entry.kind == .tool || entry.kind == .thinking {
          DisclosureGroup(isExpanded: $expanded) {
            content.padding(.top, 5)
          } label: {
            Text(expanded ? "收起详情" : summary).font(.caption)
          }
        } else {
          content
        }
      }
      .padding(12)
      .background(background, in: RoundedRectangle(cornerRadius: 12))
      Spacer(minLength: entry.kind == .user ? 70 : 10)
    }
  }

  private var content: some View {
    Text(attributedText)
      .font(entry.kind == .tool ? .system(.body, design: .monospaced) : .body)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var attributedText: AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return (try? AttributedString(markdown: entry.text, options: options))
      ?? AttributedString(entry.text)
  }

  private var summary: String {
    let firstLine = entry.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "暂无输出"
    return String(firstLine.prefix(90))
  }

  private var icon: String {
    switch entry.kind {
    case .user: "person.crop.circle.fill"
    case .assistant: "sparkles"
    case .thinking: "brain.head.profile"
    case .tool: "wrench.and.screwdriver"
    case .system: "exclamationmark.circle"
    }
  }

  private var color: Color {
    if entry.isError { return .red }
    return switch entry.kind {
    case .user: .accentColor
    case .assistant: .purple
    case .thinking: .orange
    case .tool: .blue
    case .system: .secondary
    }
  }

  private var background: Color {
    entry.kind == .user ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.07)
  }
}

private struct CodexAccountsView: View {
  @EnvironmentObject private var app: AppModel

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Label("账户额度", systemImage: "gauge.with.dots.needle.50percent")
            .font(.caption.bold())
          Spacer()
          Button {
            app.refreshCodexAccounts()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.plain)
          .disabled(app.isStreaming)
          .help("刷新额度")
          Button("管理") { app.openCodexAccountManager() }
            .buttonStyle(.plain)
            .font(.caption)
            .disabled(app.isStreaming)
        }

        if app.codexAccounts.isEmpty && app.geminiUsage == nil {
          Text(app.extensionStatuses["codex-accounts"] ?? "等待扩展提供账户信息…")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(5)
            .textSelection(.enabled)
        } else {
          ScrollView {
            LazyVStack(spacing: 7) {
              ForEach(app.codexAccounts) { account in
                accountRow(account)
              }
              if let gemini = app.geminiUsage, gemini.isConfigured {
                geminiRow(gemini)
              }
            }
          }
          .frame(maxHeight: 240)
        }

        if let updatedAt = app.codexAccountsUpdatedAt {
          Text("更新于 \(updatedAt, style: .relative)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func accountRow(_ account: CodexAccountStatus) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 5) {
        Circle()
          .fill(account.isActive ? Color.green : Color.secondary.opacity(0.35))
          .frame(width: 7, height: 7)
        Text(account.name).font(.caption.bold()).lineLimit(1)
        if account.isDefault {
          Text("默认").font(.caption2).foregroundStyle(.secondary)
        }
        if account.isHidden {
          Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary)
        }
        Spacer()
        if !account.isActive {
          Button("切换") { app.switchCodexAccount(to: account.name) }
            .buttonStyle(.borderless)
            .font(.caption2)
            .disabled(app.isStreaming)
        }
      }
      if let error = account.error {
        Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
      } else if account.primary == nil && account.secondary == nil {
        Text(account.isHidden ? "额度已隐藏" : "正在读取额度…")
          .font(.caption2).foregroundStyle(.secondary)
      } else {
        if let window = account.primary { usageRow(window, label: windowLabel(window)) }
        if let window = account.secondary { usageRow(window, label: windowLabel(window)) }
      }
    }
    .padding(7)
    .background(
      account.isActive ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 8))
  }

  private func geminiRow(_ status: GeminiUsageStatus) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 5) {
        Circle()
          .fill(status.isActive ? Color.green : Color.secondary.opacity(0.35))
          .frame(width: 7, height: 7)
        Text("Gemini").font(.caption.bold())
        Text("Antigravity").font(.caption2).foregroundStyle(.secondary)
        Spacer()
      }
      if let error = status.error {
        Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
      } else if status.quotas.isEmpty {
        Text("暂无额度数据").font(.caption2).foregroundStyle(.secondary)
      } else {
        ForEach(status.quotas) { quota in
          HStack(spacing: 5) {
            Text(geminiWindowLabel(quota.window)).frame(width: 22, alignment: .leading)
            ProgressView(value: max(0, min(100, quota.remainingPercent)), total: 100)
              .tint(usageColor(quota.remainingPercent))
            Text("\(Int(quota.remainingPercent.rounded()))%")
              .monospacedDigit().frame(width: 31, alignment: .trailing)
            if let resetAt = quota.resetAt {
              Text(resetAt, style: .relative).frame(width: 47, alignment: .trailing)
            }
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
      }
    }
    .padding(7)
    .background(
      status.isActive ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 8))
  }

  private func usageRow(_ window: CodexUsageWindow, label: String) -> some View {
    HStack(spacing: 5) {
      Text(label).frame(width: 22, alignment: .leading)
      ProgressView(value: max(0, min(100, window.remainingPercent)), total: 100)
        .tint(usageColor(window.remainingPercent))
      Text("\(Int(window.remainingPercent.rounded()))%")
        .monospacedDigit().frame(width: 31, alignment: .trailing)
      if let resetAt = window.resetAt {
        Text(resetAt, style: .relative).frame(width: 47, alignment: .trailing)
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
  }

  private func windowLabel(_ window: CodexUsageWindow) -> String {
    guard let seconds = window.windowSeconds else { return "额度" }
    return seconds <= 21_600 ? "\(Int((seconds / 3_600).rounded()))h" : "7d"
  }

  private func geminiWindowLabel(_ window: String?) -> String {
    guard let window else { return "额度" }
    if window.localizedCaseInsensitiveContains("5h")
      || window.localizedCaseInsensitiveContains("5 hour")
    {
      return "5h"
    }
    if window.localizedCaseInsensitiveContains("7d")
      || window.localizedCaseInsensitiveContains("week")
    {
      return "7d"
    }
    return "额度"
  }

  private func usageColor(_ percent: Double) -> Color {
    if percent < 20 { return .red }
    if percent < 50 { return .orange }
    return .green
  }
}

private struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State var path: String
  let save: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("设置").font(.title2.bold())
      Text("Pi 可执行文件")
      TextField("/path/to/pi", text: $path).textFieldStyle(.roundedBorder)
      Text("程序通过 Pi 的 RPC 协议运行，登录信息、模型配置、Skills 和 AGENTS.md 都继续使用 ~/.pi/agent。")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("取消") { dismiss() }
        Button("保存") {
          save(path)
          dismiss()
        }.buttonStyle(.borderedProminent)
      }
    }
    .padding(24)
    .frame(width: 520)
  }
}

private struct ExtensionDialogView: View {
  @EnvironmentObject private var app: AppModel
  let dialog: ExtensionDialog
  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(dialog.title).font(.headline)
      switch dialog.kind {
      case .select(let options):
        ForEach(options, id: \.self) { option in
          Button(option) { app.answerDialog(value: option) }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      case .confirm(let message):
        Text(message)
        HStack {
          Button("取消") { app.answerDialog(confirmed: false) }
          Button("确认") { app.answerDialog(confirmed: true) }.buttonStyle(.borderedProminent)
        }
      case .input(_, let placeholder, let multiline):
        if multiline {
          TextEditor(text: $text).frame(minHeight: 180)
        } else {
          TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
        }
        HStack {
          Button("取消") { app.answerDialog(cancelled: true) }
          Button("提交") { app.answerDialog(value: text) }.buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(24)
    .frame(minWidth: 420)
    .onAppear {
      if case .input(let initialText, _, _) = dialog.kind {
        text = initialText
      }
    }
  }
}

extension AppModel {
  fileprivate var clientConnected: Bool {
    if case .connected = connectionState { return true }
    return false
  }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var workspace: WorkspaceModel
  @State private var choosingProject = false
  @State private var choosingSession = false
  @State private var choosingAttachments = false
  @State private var showingSettings = false
  @State private var sessionNameDraft = ""
  @State private var diagnosticsExpanded = false
  @State private var composerFocused = false

  var body: some View {
    NavigationSplitView {
      redesignedSidebar
        .navigationSplitViewColumnWidth(min: 250, ideal: 292, max: 360)
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
    .fileImporter(
      isPresented: $choosingAttachments,
      allowedContentTypes: [.item],
      allowsMultipleSelection: true
    ) { result in
      if case .success(let urls) = result { app.addAttachments(urls) }
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

  private var redesignedSidebar: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          ZStack {
            RoundedRectangle(cornerRadius: 9)
              .fill(
                LinearGradient(
                  colors: [.accentColor, .purple],
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                ))
            Image(systemName: "apple.terminal.fill")
              .foregroundStyle(.white)
          }
          .frame(width: 34, height: 34)
          VStack(alignment: .leading, spacing: 1) {
            Text("Pi Mac").font(.headline)
            HStack(spacing: 5) {
              Circle().fill(app.connectionState.color).frame(width: 6, height: 6)
              Text(app.connectionState.label).lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            showingSettings = true
          } label: {
            Image(systemName: "gearshape")
          }
          .buttonStyle(.plain)
          .help("设置")
        }

        HStack(spacing: 9) {
          Image(systemName: "folder.fill")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 1) {
            Text(app.projectURL?.lastPathComponent ?? "选择工作目录")
              .font(.caption.bold())
              .lineLimit(1)
            Text(app.projectURL?.deletingLastPathComponent().path ?? "尚未连接项目")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer()
          Button {
            choosingProject = true
          } label: {
            Image(systemName: "ellipsis")
          }
          .buttonStyle(.plain)
        }
        .padding(9)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .help(app.projectURL?.path ?? "选择工作目录")

        if case .connected = app.connectionState {
          Button {
            guard let projectURL = app.projectURL else { return }
            workspace.newSession(in: projectURL)
          } label: {
            Label("新建任务", systemImage: "square.and.pencil")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)

          HStack {
            Text("会话").font(.caption.bold()).foregroundStyle(.secondary)
            Spacer()
            Button {
              choosingSession = true
            } label: {
              Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .help("打开 Session 文件")
          }

          if visibleSessions.isEmpty {
            ContentUnavailableView(
              "暂无会话",
              systemImage: "bubble.left",
              description: Text("新建任务后会显示在这里")
            )
            .controlSize(.small)
          } else {
            ScrollView {
              LazyVStack(spacing: 3) {
                ForEach(visibleSessions) { session in
                  redesignedSessionRow(session)
                }
              }
            }
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, 12)

      Spacer(minLength: 8)

      VStack(alignment: .leading, spacing: 9) {
        if app.clientConnected {
          TextField("会话名称", text: $sessionNameDraft)
            .textFieldStyle(.plain)
            .font(.caption)
            .onSubmit {
              app.sessionName = sessionNameDraft
              app.setSessionName(sessionNameDraft)
            }
            .onAppear { sessionNameDraft = app.sessionName }
            .onChange(of: app.sessionName) { _, name in sessionNameDraft = name }
        }

        CodexAccountsView().environmentObject(app)

        if let stats = app.stats {
          HStack {
            Label(stats.totalTokens.formatted(), systemImage: "text.word.spacing")
            Spacer()
            if let context = stats.contextPercent { Text("上下文 \(Int(context))%") }
            Text(stats.cost, format: .currency(code: "USD"))
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        }

        HStack {
          Button("压缩", systemImage: "arrow.down.right.and.arrow.up.left", action: app.compact)
          Spacer()
          if !app.diagnosticText.isEmpty {
            Button("诊断") { diagnosticsExpanded.toggle() }
          }
        }
        .buttonStyle(.plain)
        .font(.caption)

        if diagnosticsExpanded {
          ScrollView {
            Text(app.diagnosticText)
              .font(.caption2.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 100)
        }
      }
      .padding(12)
      .background(.ultraThinMaterial)
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.52))
  }

  private func redesignedSessionRow(_ session: SessionItem) -> some View {
    let selected = workspace.isSelectedSession(path: session.path)
    let running = workspace.model(forSessionPath: session.path)?.isStreaming == true
    return Button {
      guard let projectURL = app.projectURL else { return }
      workspace.openSession(path: session.path, in: projectURL)
    } label: {
      HStack(spacing: 9) {
        Image(systemName: running ? "circle.dotted.circle.fill" : "bubble.left")
          .foregroundStyle(running ? Color.orange : selected ? Color.accentColor : Color.secondary)
          .frame(width: 17)
        VStack(alignment: .leading, spacing: 2) {
          Text(session.title)
            .font(.callout)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(session.modifiedAt, style: .relative)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        if running { ProgressView().controlSize(.mini) }
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .contentShape(Rectangle())
      .background(
        selected ? Color.accentColor.opacity(0.13) : Color.clear,
        in: RoundedRectangle(cornerRadius: 9)
      )
    }
    .buttonStyle(.plain)
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
            if visibleSessions.isEmpty {
              Text("当前项目暂无历史会话")
                .font(.caption)
                .foregroundStyle(.tertiary)
            } else {
              ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                  ForEach(visibleSessions) { session in
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

  private var visibleSessions: [SessionItem] {
    guard let projectURL = app.projectURL else { return app.sessions }
    return workspace.sessions(in: projectURL)
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
          ForEach(conversationTurns) { turn in
            ConversationTurnView(
              turn: turn,
              isActive: app.isStreaming && turn.id == conversationTurns.last?.id,
              onEdit: { text in
                app.editMessage(text)
                composerFocused = true
              }
            )
            .id(turn.id)
          }
          Color.clear.frame(height: 44).id("conversation-bottom")
        }
        .padding(20)
      }
      .onChange(of: app.messages.count) {
        proxy.scrollTo("conversation-bottom", anchor: .bottom)
      }
      .onChange(of: app.messages.last?.text) {
        proxy.scrollTo("conversation-bottom", anchor: .bottom)
      }
    }
  }

  private var conversationTurns: [ConversationTurn] {
    var turns: [ConversationTurn] = []
    var current: [ChatEntry] = []
    for entry in app.messages {
      if entry.kind == .user, !current.isEmpty {
        turns.append(ConversationTurn(entries: current))
        current = []
      }
      current.append(entry)
    }
    if !current.isEmpty { turns.append(ConversationTurn(entries: current)) }
    return turns
  }

  private var composer: some View {
    VStack(spacing: 8) {
      ZStack(alignment: .topLeading) {
        ComposerTextView(
          text: $app.composerText,
          isFocused: $composerFocused,
          onSubmit: app.sendPrompt,
          onPasteFiles: app.addAttachments,
          onPasteImage: app.addPastedImage
        )
        .frame(minHeight: 72, maxHeight: 150)
        if app.composerText.isEmpty {
          Text("给 Pi 发送消息，或拖入图片和文件…")
            .foregroundStyle(.tertiary)
            .padding(.leading, 9)
            .padding(.top, 9)
            .allowsHitTesting(false)
        }
      }

      if !app.attachments.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(app.attachments) { attachment in
              HStack(spacing: 5) {
                Image(systemName: attachment.isImage ? "photo" : "doc")
                Text(attachment.url.lastPathComponent).lineLimit(1)
                Button {
                  app.removeAttachment(attachment)
                } label: {
                  Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
              }
              .font(.caption2)
              .padding(.horizontal, 7)
              .padding(.vertical, 4)
              .background(Color.secondary.opacity(0.10), in: Capsule())
            }
          }
        }
      }

      HStack(spacing: 8) {
        Button {
          choosingAttachments = true
        } label: {
          Image(systemName: "paperclip")
        }
        .buttonStyle(.plain)
        .help("添加图片或文件")
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
            (app.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              && app.attachments.isEmpty) || !app.clientConnected
          )
          .help("发送（Enter）")
        }
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 14))
    .dropDestination(for: URL.self) { urls, _ in
      app.addAttachments(urls)
      return !urls.isEmpty
    }
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
  let onPasteFiles: ([URL]) -> Void
  let onPasteImage: (Data, String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, isFocused: $isFocused, initialText: text)
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
    textView.onPasteFiles = onPasteFiles
    textView.onPasteImage = onPasteImage
    textView.string = text
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
    textView.onPasteFiles = onPasteFiles
    textView.onPasteImage = onPasteImage
    // AppModel 的流式事件会频繁触发 SwiftUI 更新。只有 Binding 确实发生了外部
    // 变化（例如发送后清空）才回写 NSTextView，避免旧的 View 快照覆盖刚输入的字符。
    if text != context.coordinator.lastBindingText {
      if let index = context.coordinator.pendingLocalTexts.firstIndex(of: text) {
        // 这是 NSTextView 先前产生、现在才返回的 Binding 更新。确认它，但不要
        // 用这个中间快照覆盖用户已经继续输入的新内容。
        context.coordinator.pendingLocalTexts.removeFirst(index + 1)
        context.coordinator.lastBindingText = text
      } else if !textView.hasMarkedText() {
        // Binding 来自 AppModel（例如消息发送后清空），此时才同步到原生编辑器。
        context.coordinator.pendingLocalTexts.removeAll()
        context.coordinator.lastBindingText = text
        if textView.string != text {
          textView.string = text
          textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        }
      }
    }
    if isFocused, textView.window?.firstResponder !== textView {
      DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String
    @Binding var isFocused: Bool
    weak var textView: NSTextView?
    var lastBindingText: String
    var pendingLocalTexts: [String] = []

    init(text: Binding<String>, isFocused: Binding<Bool>, initialText: String) {
      _text = text
      _isFocused = isFocused
      lastBindingText = initialText
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      let latestText = textView.string
      if pendingLocalTexts.last != latestText { pendingLocalTexts.append(latestText) }
      text = latestText
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
    var onPasteFiles: (([URL]) -> Void)?
    var onPasteImage: ((Data, String) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      if modifiers.contains(.command),
        !modifiers.contains(.shift),
        !modifiers.contains(.option),
        !modifiers.contains(.control),
        event.charactersIgnoringModifiers?.lowercased() == "v"
      {
        paste(nil)
        return true
      }
      return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
      let pasteboard = NSPasteboard.general
      let urls =
        pasteboard.readObjects(
          forClasses: [NSURL.self],
          options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
      if !urls.isEmpty {
        onPasteFiles?(urls)
        return
      }
      if let png = pasteboard.data(forType: .png) {
        onPasteImage?(png, "image/png")
        return
      }
      if let tiff = pasteboard.data(forType: .tiff),
        let representation = NSBitmapImageRep(data: tiff),
        let png = representation.representation(using: .png, properties: [:])
      {
        onPasteImage?(png, "image/png")
        return
      }
      if let image = NSImage(pasteboard: pasteboard),
        let tiff = image.tiffRepresentation,
        let representation = NSBitmapImageRep(data: tiff),
        let png = representation.representation(using: .png, properties: [:])
      {
        onPasteImage?(png, "image/png")
        return
      }
      super.paste(sender)
    }

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

private struct ConversationTurn: Identifiable {
  let entries: [ChatEntry]

  var id: String { entries.first?.id ?? UUID().uuidString }

  var user: ChatEntry? { entries.first(where: { $0.kind == .user }) }
  var finalAssistant: ChatEntry? { entries.last(where: { $0.kind == .assistant }) }
  var activity: [ChatEntry] {
    entries.filter { entry in
      entry.kind == .thinking || entry.kind == .tool
        || (entry.kind == .assistant && entry.id != finalAssistant?.id)
    }
  }
  var systemEntries: [ChatEntry] { entries.filter { $0.kind == .system } }
}

private struct ConversationTurnView: View {
  let turn: ConversationTurn
  let isActive: Bool
  let onEdit: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let user = turn.user {
        ChatEntryView(entry: user) { onEdit(user.text) }
      }
      if !turn.activity.isEmpty {
        ActivityGroupView(entries: turn.activity, taskIsRunning: isActive)
      }
      if let assistant = turn.finalAssistant { ChatEntryView(entry: assistant) }
      ForEach(turn.systemEntries) { ChatEntryView(entry: $0) }
    }
  }
}

private struct ActivityGroupView: View {
  let entries: [ChatEntry]
  let taskIsRunning: Bool
  @State private var expanded = false

  private var isRunning: Bool { taskIsRunning || entries.contains(where: \.isRunning) }
  private var toolCount: Int { entries.filter { $0.kind == .tool }.count }

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(entries) { entry in
          ActivityEntryView(entry: entry)
        }
      }
      .padding(.top, 7)
    } label: {
      HStack(spacing: 7) {
        if isRunning {
          ProgressView().controlSize(.mini)
          Text("正在处理")
        } else {
          Image(systemName: "checkmark.circle").foregroundStyle(.green)
          Text(activitySummary)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    .onAppear { expanded = isRunning }
    .onChange(of: isRunning) { wasRunning, running in
      if running { expanded = true }
      if wasRunning && !running { expanded = false }
    }
  }

  private var activitySummary: String {
    if toolCount == 0 { return "已完成思考" }
    return "已完成 · \(toolCount) 次工具调用"
  }
}

private struct ActivityEntryView: View {
  let entry: ChatEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Image(systemName: activityIcon)
        Text(entry.title).fontWeight(.medium)
        if entry.isRunning { ProgressView().controlSize(.mini) }
      }
      .font(.caption)
      .foregroundStyle(entry.isError ? Color.red : Color.secondary)

      if let diff = entry.diff, !diff.isEmpty {
        GitDiffView(diff: diff)
      } else if !entry.text.isEmpty {
        Text(entry.text)
          .font(.system(.caption, design: entry.kind == .tool ? .monospaced : .default))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.leading, 4)
  }

  private var activityIcon: String {
    switch entry.kind {
    case .thinking: "brain.head.profile"
    case .tool: "wrench.and.screwdriver"
    case .assistant: "sparkles"
    case .user: "person.crop.circle"
    case .system: "exclamationmark.circle"
    }
  }
}

private struct GitDiffView: View {
  let diff: String

  var body: some View {
    ScrollView(.horizontal) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          Text(line.isEmpty ? " " : line)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(foreground(for: line))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(for: line))
        }
      }
      .textSelection(.enabled)
    }
    .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.16)))
  }

  private var lines: [String] {
    diff.components(separatedBy: .newlines)
  }

  private func background(for line: String) -> Color {
    if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green.opacity(0.14) }
    if line.hasPrefix("-") && !line.hasPrefix("---") { return .red.opacity(0.14) }
    if line.hasPrefix("@@") { return .blue.opacity(0.10) }
    return .clear
  }

  private func foreground(for line: String) -> Color {
    if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
    if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
    if line.hasPrefix("@@") { return .blue }
    return .primary
  }
}

private struct ChatEntryView: View {
  let entry: ChatEntry
  let onEdit: (() -> Void)?
  @State private var expanded: Bool

  init(entry: ChatEntry, onEdit: (() -> Void)? = nil) {
    self.entry = entry
    self.onEdit = onEdit
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
          Spacer()
          if let onEdit {
            Button(action: onEdit) {
              Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("重新编辑这条消息")
          }
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
  @State private var isExpanded = false

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
          Button {
            withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
          } label: {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          }
          .buttonStyle(.plain)
          .help(isExpanded ? "折叠账户额度" : "展开全部账户额度")
        }

        if isExpanded {
          expandedAccounts
          if let updatedAt = app.codexAccountsUpdatedAt {
            Text("更新于 \(updatedAt, style: .relative)")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        } else {
          currentAccount
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private var expandedAccounts: some View {
    if app.codexAccounts.isEmpty && app.geminiUsage == nil {
      emptyStatus
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
  }

  @ViewBuilder
  private var currentAccount: some View {
    if let gemini = app.geminiUsage, gemini.isConfigured, gemini.isActive {
      geminiRow(gemini)
    } else if let account = app.codexAccounts.first(where: \.isActive) {
      accountRow(account)
    } else {
      emptyStatus
    }
  }

  private var emptyStatus: some View {
    Text(app.extensionStatuses["codex-accounts"] ?? "等待扩展提供账户信息…")
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(5)
      .textSelection(.enabled)
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

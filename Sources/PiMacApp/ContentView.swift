import AppKit
import SwiftUI
import UniformTypeIdentifiers

private func thinkingLevelLabel(_ level: String) -> String {
  let chinese: String
  switch level {
  case "off": chinese = "不思考"
  case "minimal": chinese = "最简"
  case "low": chinese = "低"
  case "medium": chinese = "中等"
  case "high": chinese = "高"
  case "xhigh": chinese = "超高"
  case "max": chinese = "最大"
  default: chinese = level
  }
  return chinese == level ? level : "\(chinese) · \(level)"
}

private func isWhitespace(in text: NSString, before location: Int) -> Bool {
  guard location > 0, let scalar = UnicodeScalar(text.character(at: location - 1)) else {
    return false
  }
  return CharacterSet.whitespacesAndNewlines.contains(scalar)
}

private struct ConversationBottomPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

private enum ConversationScrollMode {
  case pinnedToBottom
  case manual
}

private enum ConversationLayout {
  static let contentInset: CGFloat = 20
  static let bottomAnchorID = "conversation-bottom"
}

/// SwiftUI does not expose scroll phases on macOS 14. Observe AppKit's live-scroll
/// notifications so content growth is never mistaken for a user's scroll gesture.
private struct ConversationScrollObserver: NSViewRepresentable {
  let onUserScroll: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onUserScroll: onUserScroll)
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async { context.coordinator.attach(to: view.enclosingScrollView) }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.onUserScroll = onUserScroll
    DispatchQueue.main.async { context.coordinator.attach(to: view.enclosingScrollView) }
  }

  final class Coordinator {
    var onUserScroll: () -> Void
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []

    init(onUserScroll: @escaping () -> Void) {
      self.onUserScroll = onUserScroll
    }

    deinit {
      observers.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(to scrollView: NSScrollView?) {
      guard let scrollView, self.scrollView !== scrollView else { return }
      observers.forEach(NotificationCenter.default.removeObserver)
      observers.removeAll()
      self.scrollView = scrollView
      // 对话底部是一个真实的内容边界，不允许橡皮筋效果把最后一条消息
      // 临时拖到固定留白之外。
      scrollView.verticalScrollElasticity = .none

      for name in [
        NSScrollView.willStartLiveScrollNotification,
        NSScrollView.didLiveScrollNotification,
      ] {
        observers.append(
          NotificationCenter.default.addObserver(
            forName: name,
            object: scrollView,
            queue: .main
          ) { [weak self] _ in
            self?.onUserScroll()
          })
      }
    }
  }
}

private struct CompactResetTime: View {
  let date: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      Text(Self.label(for: date, relativeTo: context.date))
    }
  }

  private static func label(for date: Date, relativeTo now: Date) -> String {
    let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
    if minutes == 0 { return "NOW" }

    let days = minutes / 1_440
    let hours = minutes % 1_440 / 60
    let remainingMinutes = minutes % 60
    if days > 0 { return hours > 0 ? "\(days)D\(hours)H" : "\(days)D" }
    if hours > 0 { return remainingMinutes > 0 ? "\(hours)H\(remainingMinutes)M" : "\(hours)H" }
    return "\(remainingMinutes)M"
  }
}

private struct SessionRelativeTime: View {
  let date: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      Text(Self.label(for: date, relativeTo: context.date))
    }
  }

  private static func label(for date: Date, relativeTo now: Date) -> String {
    let interval = date.timeIntervalSince(now)
    if abs(interval) < 60 {
      return interval > 0 ? "不到 1 分钟后" : "不到 1 分钟前"
    }

    // Quantize to whole minutes so the session list never displays or updates by seconds.
    let wholeMinutes = (interval / 60).rounded(.towardZero)
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = .current
    formatter.unitsStyle = .full
    return formatter.localizedString(fromTimeInterval: wholeMinutes * 60)
  }
}

struct ContentView: View {
  let tabID: UUID

  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var workspace: WorkspaceModel
  @EnvironmentObject private var extensionUI: ExtensionUIModel
  @State private var choosingProject = false
  @State private var choosingSession = false
  @State private var choosingAttachments = false
  @State private var showingSettings = false
  @State private var showingModelSettings = false
  @State private var previewedAttachment: PromptAttachment?
  @State private var composerFocused = false
  @State private var composerSelection = NSRange(location: 0, length: 0)
  @State private var conversationScrollMode: ConversationScrollMode = .pinnedToBottom
  @State private var autoScrollScheduled = false
  @State private var autoScrollGeneration = 0
  @State private var initialSessionScrollPending = true
  @State private var initialScrollGeneration = 0
  @State private var conversationBottomIsVisible = false
  @State private var visibleSessionCount = 10
  @State private var hoveredSessionPath: String?
  @AppStorage("projectsCollapsed") private var projectsCollapsed = false

  var body: some View {
    HStack(spacing: 0) {
      redesignedSidebar
        .frame(width: 292)

      VStack(spacing: 0) {
        conversation
        Divider()
        composer
      }
      // Keep this subtree alive across task changes. Re-keying even only the detail pane tears
      // down its AppKit-backed scroll/editor views; because the sidebar uses translucent
      // material, that teardown is visible as a flash across the entire left column. Per-task
      // transient state is reset explicitly in the tabID change handler below instead.
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
      if case .success(let urls) = result { addAttachmentsAtSelection(urls) }
    }
    .sheet(isPresented: $showingSettings) {
      SettingsView(path: app.piPath, projectURL: app.projectURL) { app.piPath = $0 }
    }
    .sheet(isPresented: $showingModelSettings) {
      ModelSettingsView()
        .environmentObject(app)
    }
    .sheet(item: $previewedAttachment) { attachment in
      ImageAttachmentPreview(attachment: attachment)
    }
    .sheet(item: $extensionUI.dialog) { dialog in
      ExtensionDialogView(dialog: dialog)
        .interactiveDismissDisabled()
    }
    .onChange(of: app.connectionState) {
      if case .connected = app.connectionState {
        composerFocused = true
      }
    }
    .onChange(of: app.projectURL?.standardizedFileURL.path) {
      visibleSessionCount = 10
    }
    .onChange(of: tabID) {
      composerSelection = NSRange(location: 0, length: 0)
      conversationScrollMode = .pinnedToBottom
      autoScrollScheduled = false
      autoScrollGeneration += 1
      initialSessionScrollPending = true
      initialScrollGeneration += 1
      conversationBottomIsVisible = false
      previewedAttachment = nil
    }
  }

  private var redesignedSidebar: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 9) {
          HStack(spacing: 7) {
            Text("Pi Mac").font(.headline)
            HStack(spacing: 4) {
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

        HStack {
          Text("项目").font(.caption.bold()).foregroundStyle(.secondary)
          Spacer()
          if !workspace.projects.isEmpty {
            Button {
              withAnimation(.easeInOut(duration: 0.16)) {
                projectsCollapsed.toggle()
              }
            } label: {
              Image(
                systemName: projectsCollapsed ? "rectangle.grid.1x2" : "rectangle.grid.1x2.fill")
            }
            .buttonStyle(.plain)
            .help(projectsCollapsed ? "展开项目" : "折叠为图标")
          }
          Button {
            choosingProject = true
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.plain)
          .help("添加项目")
        }

        if workspace.projects.isEmpty {
          Button("添加项目…", systemImage: "folder.badge.plus") { choosingProject = true }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if projectsCollapsed {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
              ForEach(workspace.projects) { project in
                compactProjectButton(project)
              }
            }
            .padding(.vertical, 1)
          }
        } else {
          LazyVStack(spacing: 3) {
            ForEach(workspace.projects) { project in
              projectRow(project)
            }
          }
        }

        if app.projectURL != nil {
          Button {
            guard let projectURL = app.projectURL else { return }
            workspace.newSession(in: projectURL)
          } label: {
            Label("新建任务", systemImage: "square.and.pencil")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(!app.clientConnectedForCommands)

          Text("会话")
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

          if visibleSessions.isEmpty, let projectURL = app.projectURL,
            workspace.isLoadingSessions(in: projectURL)
          {
            HStack(spacing: 8) {
              ProgressView().controlSize(.small)
              Text("正在读取会话…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
          } else if visibleSessions.isEmpty {
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
                if hasMoreSessions {
                  loadMoreSessionsButton
                }
              }
            }
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, 8)

      Spacer(minLength: 8)

      VStack(alignment: .leading, spacing: 9) {
        CodexAccountsView().environmentObject(app)
      }
      .padding(12)
      .background(.ultraThinMaterial)
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.52))
  }

  private func compactProjectButton(_ project: WorkspaceProject) -> some View {
    let selected = workspace.selectedProject?.id == project.id
    return Button {
      workspace.selectProject(project)
    } label: {
      projectIcon(project, size: 34)
        .padding(3)
        .background(
          selected ? Color.accentColor.opacity(0.18) : Color.clear,
          in: RoundedRectangle(cornerRadius: 11)
        )
    }
    .buttonStyle(.plain)
    .help(project.name)
    .contextMenu {
      Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
      Divider()
      Button("从列表移除", role: .destructive) { workspace.removeProject(project) }
    }
  }

  private func projectIcon(_ project: WorkspaceProject, size: CGFloat) -> some View {
    let palette: [(Color, Color)] = [
      (.blue, .cyan), (.purple, .pink), (.orange, .red), (.green, .teal), (.indigo, .purple),
      (.mint, .blue),
    ]
    let scalarTotal = project.name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    let colors = palette[scalarTotal % palette.count]
    let initial = String(project.name.prefix(1)).uppercased()
    return ZStack {
      RoundedRectangle(cornerRadius: size * 0.26)
        .fill(
          LinearGradient(
            colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing))
      Text(initial)
        .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
    }
    .frame(width: size, height: size)
  }

  private func projectRow(_ project: WorkspaceProject) -> some View {
    let selected = workspace.selectedProject?.id == project.id
    return Button {
      workspace.selectProject(project)
    } label: {
      HStack(spacing: 8) {
        projectIcon(project, size: 29)
        VStack(alignment: .leading, spacing: 1) {
          Text(project.name).font(.callout).lineLimit(1)
          Text(project.url.deletingLastPathComponent().path)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        if selected {
          Circle().fill(Color.accentColor).frame(width: 6, height: 6)
        }
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
      .background(
        selected ? Color.accentColor.opacity(0.11) : Color.clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
      Divider()
      Button("从列表移除", role: .destructive) { workspace.removeProject(project) }
    }
  }

  private func redesignedSessionRow(_ session: SessionItem) -> some View {
    let selected = workspace.isSelectedSession(path: session.path)
    let running = workspace.model(forSessionPath: session.path)?.isBusy == true
    let hovered = hoveredSessionPath == session.path
    return ZStack(alignment: .trailing) {
      Button {
        guard let projectURL = app.projectURL else { return }
        workspace.openSession(path: session.path, in: projectURL)
      } label: {
        HStack(spacing: 9) {
          Image(systemName: selected ? "bubble.left.fill" : "bubble.left")
            .foregroundStyle(
              running ? Color.orange : selected ? Color.accentColor : Color.secondary
            )
            .frame(width: 17)
          VStack(alignment: .leading, spacing: 2) {
            Text(session.title)
              .font(.callout)
              .lineLimit(2)
              .frame(maxWidth: .infinity, alignment: .leading)
            SessionRelativeTime(date: session.modifiedAt)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.leading, 9)
        .padding(.trailing, 38)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if hovered {
        Button {
          guard let projectURL = app.projectURL else { return }
          workspace.archiveSession(path: session.path, in: projectURL)
        } label: {
          Image(systemName: "archivebox")
            .frame(width: 26, height: 26)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(running)
        .help(running ? "任务运行时不能归档" : "归档会话")
        .padding(.trailing, 6)
        .transition(.opacity)
      }
    }
    .background(
      selected ? Color.accentColor.opacity(0.13) : Color.clear,
      in: RoundedRectangle(cornerRadius: 9)
    )
    .contentShape(Rectangle())
    .onHover { isHovered in
      withAnimation(.easeOut(duration: 0.12)) {
        hoveredSessionPath = isHovered ? session.path : nil
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
            HStack {
              Button("新会话", systemImage: "plus.bubble") {
                guard let projectURL = app.projectURL else { return }
                workspace.newSession(in: projectURL)
              }
              .help("在当前窗口创建并切换到新会话；其他任务继续在后台运行")
              Button("打开…", systemImage: "folder") { choosingSession = true }
            }
            Button("压缩上下文", systemImage: "arrow.down.right.and.arrow.up.left", action: app.compact)
              .disabled(app.isBusy)

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
                          SessionRelativeTime(date: session.modifiedAt)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                      }
                      .contentShape(Rectangle())
                      .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                  }
                  if hasMoreSessions {
                    loadMoreSessionsButton
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

      Spacer()

      CodexAccountsView()
        .environmentObject(app)

      if let stats = app.stats {
        VStack(alignment: .leading, spacing: 4) {
          Text("\(stats.totalTokens.formatted()) tokens")
          Text(stats.contextPercent.map { "上下文 \(Int($0))%" } ?? "上下文统计等待更新")
            .foregroundStyle(contextUsageColor(stats.contextPercent))
          Text(stats.cacheHitPercent.map { "缓存命中 \(Int($0.rounded()))%" } ?? "缓存命中 --")
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

  private var allSessions: [SessionItem] {
    guard let projectURL = app.projectURL else { return app.sessions }
    return workspace.sessions(in: projectURL)
  }

  private var visibleSessions: [SessionItem] {
    Array(allSessions.prefix(visibleSessionCount))
  }

  private var hasMoreSessions: Bool {
    visibleSessions.count < allSessions.count
  }

  private var loadMoreSessionsButton: some View {
    Button {
      visibleSessionCount = min(visibleSessionCount + 10, allSessions.count)
    } label: {
      Label("载入更多", systemImage: "chevron.down")
        .font(.caption)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
  }

  private var conversation: some View {
    let turns = conversationTurns

    return GeometryReader { viewport in
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if app.messages.isEmpty {
              ContentUnavailableView(
                "开始和 Pi 对话",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Pi 可以读取、编辑文件并执行项目命令。")
              )
              .frame(maxWidth: .infinity, minHeight: 360)
            }

            VirtualConversationStack(
              ids: turns.map(\.id),
              pinnedToBottom: conversationScrollMode == .pinnedToBottom
            ) { index in
              conversationTurnView(
                turns[index], isActive: app.isStreaming && index == turns.count - 1
              )
            }
            // Height caches and viewport coordinates must never leak across sessions.
            .id("\(tabID)-\(app.currentSessionPath)")

            // The footer is the real content edge as well as the auto-scroll anchor.
            Color.clear
              .frame(height: ConversationLayout.contentInset)
              .id(ConversationLayout.bottomAnchorID)
              .background {
                GeometryReader { marker in
                  Color.clear.preference(
                    key: ConversationBottomPreferenceKey.self,
                    value: marker.frame(in: .named("conversation-scroll")).maxY
                  )
                }
              }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, ConversationLayout.contentInset)
          .padding(.top, ConversationLayout.contentInset)
          .background {
            ConversationScrollObserver(onUserScroll: enterManualScrollMode)
              .frame(width: 0, height: 0)
          }
        }
        .coordinateSpace(name: "conversation-scroll")
        .scrollIndicators(.hidden)
        // 让长会话在首帧布局时就以底部为基准，避免先显示靠上的位置，
        // 再等待延迟校正滚到底部。后续显式滚动仍用于 Markdown 高度变化。
        .defaultScrollAnchor(.bottom)
        .onAppear {
          // 会话内容通过 RPC 异步到达；保持首次滚动待处理，直到消息完成首轮布局。
          initialSessionScrollPending = true
          conversationBottomIsVisible = false
          scheduleInitialSessionScroll(proxy)
        }
        .onPreferenceChange(ConversationBottomPreferenceKey.self) { bottomY in
          guard bottomY.isFinite, bottomY > 0 else { return }
          conversationBottomIsVisible = bottomY <= viewport.size.height + 1
          if bottomY <= viewport.size.height + 1 {
            // 手动滚回底部后，重新进入固定底部模式。
            conversationScrollMode = .pinnedToBottom
          }
          // Follow actual layout changes rather than speculative repeated corrections.
          if !conversationBottomIsVisible && !initialSessionScrollPending {
            scheduleAutoScroll(proxy)
          }
        }
        .onChange(of: app.messages.count) {
          if initialSessionScrollPending {
            // defaultScrollAnchor 已经会把首帧放到底部。此时只安排一次布局稳定后的
            // 兜底校正，避免多个延迟 scrollTo 造成可见跳动。
            scheduleInitialSessionScroll(proxy)
          } else {
            scheduleAutoScroll(proxy)
          }
        }
        .onChange(of: app.messages.last?.text) {
          scheduleAutoScroll(proxy)
        }
        .onChange(of: app.isStreaming) { wasStreaming, isStreaming in
          scheduleAutoScroll(
            proxy,
            force: wasStreaming && !isStreaming && conversationScrollMode == .pinnedToBottom
          )
        }
        .onChange(of: app.currentSessionPath) {
          autoScrollGeneration += 1
          autoScrollScheduled = false
          conversationScrollMode = .pinnedToBottom
          initialSessionScrollPending = true
          conversationBottomIsVisible = false
          scheduleInitialSessionScroll(proxy)
        }
      }
    }
  }

  private func conversationTurnView(
    _ turn: ConversationTurn,
    isActive: Bool
  ) -> some View {
    ConversationTurnView(
      turn: turn,
      isActive: isActive,
      onEdit: { text in
        app.editMessage(text)
        composerFocused = true
      }
    )
    .id(turn.id)
  }

  private func scheduleInitialSessionScroll(_ proxy: ScrollViewProxy) {
    initialScrollGeneration += 1
    let generation = initialScrollGeneration

    // RPC 返回、VStack 创建子视图以及 Markdown 定高并不在同一轮布局中。
    // 等布局稳定后再执行最终定位；若期间消息继续到达，旧任务会自动失效。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
      guard generation == initialScrollGeneration, !app.messages.isEmpty else { return }
      // defaultScrollAnchor 通常已经完成定位。只有底部确实还在视口外时才校正，
      // 避免重复 scrollTo 的像素级位置差让整段内容在进入会话后向下跳。
      if !conversationBottomIsVisible {
        proxy.scrollTo(ConversationLayout.bottomAnchorID, anchor: .bottom)
      }
      conversationScrollMode = .pinnedToBottom
      initialSessionScrollPending = false
    }
  }

  private func scheduleAutoScroll(_ proxy: ScrollViewProxy, force: Bool = false) {
    if force { conversationScrollMode = .pinnedToBottom }
    guard !initialSessionScrollPending,
      conversationScrollMode == .pinnedToBottom, !autoScrollScheduled
    else { return }
    autoScrollScheduled = true
    autoScrollGeneration += 1
    let generation = autoScrollGeneration

    // Coalesce updates into one correction; subsequent height changes are observed above.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      guard generation == autoScrollGeneration,
        conversationScrollMode == .pinnedToBottom
      else { return }
      autoScrollScheduled = false
      if !conversationBottomIsVisible {
        proxy.scrollTo(ConversationLayout.bottomAnchorID, anchor: .bottom)
      }
    }
  }

  private func enterManualScrollMode() {
    conversationScrollMode = .manual
    autoScrollGeneration += 1
    autoScrollScheduled = false

    // 用户操作优先于会话打开后的延迟定位。
    initialScrollGeneration += 1
    initialSessionScrollPending = false
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
      if !app.queuedPrompts.isEmpty {
        VStack(spacing: 5) {
          ForEach(app.queuedPrompts) { prompt in
            queuedPromptRow(prompt)
          }
        }
        .padding(7)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
      }

      ZStack(alignment: .topLeading) {
        ComposerTextView(
          text: $app.composerText,
          selection: $composerSelection,
          isFocused: $composerFocused,
          onSubmit: { sendPromptFollowingOutput(delivery: .steer) },
          onFollowUp: { sendPromptFollowingOutput(delivery: .followUp) },
          onPasteFiles: registerAttachments,
          onPasteImage: registerPastedImage
        )
        .frame(minHeight: 72, maxHeight: 150)
        .clipped()
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
          HStack(spacing: 7) {
            ForEach(app.attachments) { attachment in
              composerAttachment(attachment)
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
        sessionControls
        Spacer()
        if !app.statusText.isEmpty {
          ProgressView().controlSize(.small)
          Text(app.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        let promptIsEmpty =
          app.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && app.attachments.isEmpty
        if app.isStreaming {
          Button {
            sendPromptFollowingOutput(delivery: .steer)
          } label: {
            Label("工具后", systemImage: "arrow.turn.down.right")
              .font(.caption)
          }
          .buttonStyle(.borderedProminent)
          .disabled(promptIsEmpty || !app.clientConnected)
          .help("当前工具调用阶段结束后插入（Return）")

          Button {
            sendPromptFollowingOutput(delivery: .followUp)
          } label: {
            Label("完成后", systemImage: "clock")
              .font(.caption)
          }
          .buttonStyle(.bordered)
          .disabled(promptIsEmpty || !app.clientConnected)
          .help("当前任务全部完成后继续（⌥ Return）")

          stopButton
        } else if app.isCompacting {
          Button {
            sendPromptFollowingOutput(delivery: .steer)
          } label: {
            Label("压缩后", systemImage: "clock")
              .font(.caption)
          }
          .buttonStyle(.bordered)
          .disabled(promptIsEmpty || !app.clientConnected)
          .help("上下文压缩完成后发送（Return）")

          stopButton
        } else {
          Button {
            sendPromptFollowingOutput(delivery: .steer)
          } label: {
            Image(systemName: "arrow.up")
              .font(.body.bold())
              .frame(width: 26, height: 26)
          }
          .buttonStyle(.borderedProminent)
          .clipShape(Circle())
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(promptIsEmpty || !app.clientConnected)
          .help("发送（Enter）")
        }
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 14))
    .dropDestination(for: URL.self) { urls, _ in
      addAttachmentsAtSelection(urls)
      return !urls.isEmpty
    }
    .padding(12)
  }

  private func queuedPromptRow(_ prompt: QueuedPrompt) -> some View {
    HStack(spacing: 7) {
      Group {
        if prompt.waitsForCompaction {
          Text("压缩完成后").foregroundStyle(.secondary)
        } else if prompt.delivery == .steer {
          Text(prompt.delivery.label).foregroundStyle(.orange)
        } else {
          Text(prompt.delivery.label).foregroundStyle(.blue)
        }
      }
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(.quaternary, in: Capsule())

      Text(prompt.text.replacingOccurrences(of: "\n", with: " "))
        .font(.caption)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        app.editQueuedPrompt(id: prompt.id)
        composerFocused = true
      } label: {
        Image(systemName: "pencil")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("重新编辑这条尚未发送的消息")

      Button {
        app.removeQueuedPrompt(id: prompt.id)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("删除这条尚未发送的消息")
    }
  }

  @ViewBuilder
  private func composerAttachment(_ attachment: PromptAttachment) -> some View {
    if attachment.isImage, let image = NSImage(contentsOf: attachment.url) {
      ZStack(alignment: .topTrailing) {
        Button {
          previewedAttachment = attachment
        } label: {
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 62, height: 48)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("点击预览 \(attachment.url.lastPathComponent)")

        Button {
          removeAttachment(attachment)
        } label: {
          Image(systemName: "xmark.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.65))
        }
        .buttonStyle(.plain)
        .padding(3)
      }
    } else {
      HStack(spacing: 5) {
        Image(systemName: "doc")
        Text(attachment.url.lastPathComponent).lineLimit(1)
        Button {
          removeAttachment(attachment)
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

  private func registerAttachments(_ urls: [URL]) -> [String] {
    app.addAttachments(urls).map(\.composerReference)
  }

  private func registerPastedImage(_ data: Data, _ mimeType: String) -> [String] {
    app.addPastedImage(data, mimeType: mimeType).map(\.composerReference)
  }

  private func addAttachmentsAtSelection(_ urls: [URL]) {
    insertComposerReferences(registerAttachments(urls))
  }

  private func insertComposerReferences(_ references: [String]) {
    guard !references.isEmpty else { return }
    let source = app.composerText as NSString
    let location = min(composerSelection.location, source.length)
    let length = min(composerSelection.length, source.length - location)
    let range = NSRange(location: location, length: length)
    let insertion = references.joined(separator: " ")
    let leadingSpace = location > 0 && !isWhitespace(in: source, before: location) ? " " : ""
    let trailingSpace = location + length < source.length ? " " : ""
    let replacement = leadingSpace + insertion + trailingSpace
    app.composerText = source.replacingCharacters(in: range, with: replacement)
    composerSelection = NSRange(location: location + replacement.utf16.count, length: 0)
    composerFocused = true
  }

  private func removeAttachment(_ attachment: PromptAttachment) {
    app.removeAttachment(attachment)
    if let range = app.composerText.range(of: attachment.composerReference) {
      app.composerText.removeSubrange(range)
    }
  }

  private var stopButton: some View {
    Button(action: app.abort) {
      Image(systemName: "stop.fill")
        .font(.caption.bold())
        .frame(width: 26, height: 26)
    }
    .buttonStyle(.borderedProminent)
    .tint(.red)
    .clipShape(Circle())
    .help(app.isCompacting ? "停止压缩" : "停止当前任务")
  }

  private func sendPromptFollowingOutput(delivery: QueuedPromptDelivery) {
    // 发送消息明确恢复固定底部模式；随后的用户滚动仍可立即切回手动模式。
    conversationScrollMode = .pinnedToBottom
    app.sendPrompt(delivery: delivery)
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
        .disabled(app.isBusy)
      }
      Divider()
      Button("管理模型与默认思考等级…", systemImage: "slider.horizontal.3") {
        showingModelSettings = true
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "sparkles")
        Text(app.allModels.first(where: { $0.id == app.selectedModelId })?.name ?? "选择模型")
          .lineLimit(1)
        Image(systemName: "chevron.down").font(.caption2)
      }
      .font(.caption)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(app.allModels.isEmpty)
  }

  private var sessionControls: some View {
    HStack(spacing: 7) {
      Button(action: app.compact) {
        HStack(spacing: 4) {
          Image(systemName: "arrow.down.right.and.arrow.up.left")
          Text("压缩")
        }
        .font(.body)
      }
      .buttonStyle(.plain)
      .disabled(app.isBusy)
      .help("压缩上下文")

      if let stats = app.stats {
        Divider().frame(height: 14)
        HStack(spacing: 7) {
          Text(stats.contextPercent.map { "上下文 \(Int($0))%" } ?? "上下文 --")
            .foregroundStyle(contextUsageColor(stats.contextPercent))
          Text("\(stats.totalTokens.formatted()) tokens")
          Text(stats.cacheHitPercent.map { "缓存命中 \(Int($0.rounded()))%" } ?? "缓存命中 --")
          Text(stats.cost, format: .currency(code: "USD"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .fixedSize()
  }

  private func contextUsageColor(_ percent: Double?) -> Color {
    guard let percent else { return .secondary }
    if percent > 60 { return .red }
    if percent > 40 { return .orange }
    return .secondary
  }

  private var thinkingMenu: some View {
    Menu {
      ForEach(app.thinkingLevels, id: \.self) { level in
        Button {
          app.changeThinkingLevel(to: level)
        } label: {
          if level == app.selectedThinkingLevel {
            Label(thinkingLevelLabel(level), systemImage: "checkmark")
          } else {
            Text(thinkingLevelLabel(level))
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "brain.head.profile")
        Text(thinkingLevelLabel(app.selectedThinkingLevel))
        Image(systemName: "chevron.down").font(.caption2)
      }
      .font(.caption)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(app.isBusy)
  }

}

private struct ComposerTextView: NSViewRepresentable {
  @Binding var text: String
  @Binding var selection: NSRange
  @Binding var isFocused: Bool
  let onSubmit: () -> Void
  let onFollowUp: () -> Void
  let onPasteFiles: ([URL]) -> [String]
  let onPasteImage: (Data, String) -> [String]

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, selection: $selection, isFocused: $isFocused, initialText: text)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = BorderlessScrollView()
    scrollView.drawsBackground = false
    scrollView.backgroundColor = .clear
    scrollView.borderType = .noBorder
    scrollView.focusRingType = .none
    scrollView.contentView.drawsBackground = false
    scrollView.contentView.backgroundColor = .clear
    scrollView.wantsLayer = true
    scrollView.layer?.backgroundColor = NSColor.clear.cgColor
    scrollView.layer?.borderWidth = 0
    scrollView.layer?.shadowOpacity = 0
    scrollView.contentView.wantsLayer = true
    scrollView.contentView.layer?.backgroundColor = NSColor.clear.cgColor
    scrollView.contentView.layer?.borderWidth = 0
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    let textView = SubmitTextView(frame: scrollView.contentView.bounds)
    textView.delegate = context.coordinator
    textView.onSubmit = onSubmit
    textView.onFollowUp = onFollowUp
    textView.onPasteFiles = onPasteFiles
    textView.onPasteImage = onPasteImage
    textView.string = text
    textView.isRichText = false
    textView.importsGraphics = false
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.focusRingType = .none
    textView.allowsUndo = true
    textView.font = .systemFont(ofSize: NSFont.systemFontSize)
    textView.textContainerInset = NSSize(width: 7, height: 8)
    textView.minSize = NSSize(width: 0, height: 72)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )
    scrollView.documentView = textView
    // Setting the document view can cause AppKit to restore its platform-default border.
    scrollView.borderType = .noBorder
    context.coordinator.textView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? SubmitTextView else { return }
    // The representable now survives task switches. Rebind its coordinator to the currently
    // selected AppModel; otherwise NSTextView continues writing into the previous task's
    // composer while the current binding stays empty and keeps the placeholder visible.
    context.coordinator.updateBindings(
      text: $text, selection: $selection, isFocused: $isFocused)
    textView.onSubmit = onSubmit
    textView.onFollowUp = onFollowUp
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
          let location = min(selection.location, text.utf16.count)
          textView.setSelectedRange(NSRange(location: location, length: 0))
        }
      }
    }
    if isFocused, textView.window?.firstResponder !== textView {
      DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
    }
  }

  final class BorderlessScrollView: NSScrollView {
    override var isOpaque: Bool { false }

    // macOS 27 draws a one-pixel legacy frame even when borderType is .noBorder.
    // The clip view and scrollers are subviews, so suppressing this view's own
    // drawing removes that frame without affecting scrolling or text rendering.
    override func draw(_ dirtyRect: NSRect) {}
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var isFocused: Bool
    weak var textView: NSTextView?
    var lastBindingText: String
    var pendingLocalTexts: [String] = []

    init(
      text: Binding<String>, selection: Binding<NSRange>, isFocused: Binding<Bool>,
      initialText: String
    ) {
      _text = text
      _selection = selection
      _isFocused = isFocused
      lastBindingText = initialText
    }

    func updateBindings(
      text: Binding<String>, selection: Binding<NSRange>, isFocused: Binding<Bool>
    ) {
      _text = text
      _selection = selection
      _isFocused = isFocused
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      let latestText = textView.string
      if pendingLocalTexts.last != latestText { pendingLocalTexts.append(latestText) }
      text = latestText
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      selection = textView.selectedRange()
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
    var onFollowUp: (() -> Void)?
    var onPasteFiles: (([URL]) -> [String])?
    var onPasteImage: ((Data, String) -> [String])?

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
        insertAttachmentReferences(onPasteFiles?(urls) ?? [])
        return
      }
      if let png = pasteboard.data(forType: .png) {
        insertAttachmentReferences(onPasteImage?(png, "image/png") ?? [])
        return
      }
      if let tiff = pasteboard.data(forType: .tiff),
        let representation = NSBitmapImageRep(data: tiff),
        let png = representation.representation(using: .png, properties: [:])
      {
        insertAttachmentReferences(onPasteImage?(png, "image/png") ?? [])
        return
      }
      if let image = NSImage(pasteboard: pasteboard),
        let tiff = image.tiffRepresentation,
        let representation = NSBitmapImageRep(data: tiff),
        let png = representation.representation(using: .png, properties: [:])
      {
        insertAttachmentReferences(onPasteImage?(png, "image/png") ?? [])
        return
      }
      super.paste(sender)
    }

    private func insertAttachmentReferences(_ references: [String]) {
      guard !references.isEmpty else { return }
      let insertion = references.joined(separator: " ")
      let source = string as NSString
      let range = selectedRange()
      let leadingSpace =
        range.location > 0 && !isWhitespace(in: source, before: range.location) ? " " : ""
      let trailingSpace = range.location + range.length < source.length ? " " : ""
      insertText(leadingSpace + insertion + trailingSpace, replacementRange: range)
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
        // 交给 NSTextView 处理，确保输入法也能看到完整的 Shift+Enter 组合。
        // 直接插入换行会绕过 NSTextInputContext，使部分输入法把 Shift 松开
        // 误判为单独按下 Shift，进而切换中英文。
        super.keyDown(with: event)
        return
      }
      if modifiers.contains(.option) {
        onFollowUp?()
      } else {
        onSubmit?()
      }
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
  var supplementaryEntries: [ChatEntry] {
    entries.filter { $0.kind == .system || $0.kind == .compaction }
  }
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
      ForEach(turn.supplementaryEntries) { ChatEntryView(entry: $0) }
    }
  }
}

private struct ActivityGroupView: View {
  let entries: [ChatEntry]
  let taskIsRunning: Bool
  @Environment(\.conversationExpansionStore) private var expansionStore
  @State private var localExpanded = false

  private var expansionKey: String { "activity-\(entries.first?.id ?? "empty")" }
  private var expanded: Bool {
    get { expansionStore?.values[expansionKey] ?? localExpanded }
    nonmutating set {
      localExpanded = newValue
      expansionStore?.values[expansionKey] = newValue
    }
  }

  private var hasRunningActivity: Bool { entries.contains(where: \.isRunning) }
  private var shouldStayExpanded: Bool { taskIsRunning || hasRunningActivity }
  private var toolCount: Int { entries.filter { $0.kind == .tool }.count }
  private var failedToolCount: Int {
    entries.filter { $0.kind == .tool && $0.isError }.count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
      } label: {
        HStack(spacing: 9) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 10)
          activityStatusIcon
          Text(activitySummary)
            .font(.caption.weight(.medium))
          if toolCount > 0 {
            HStack(spacing: 4) {
              Text("\(toolCount) 次调用")
                .foregroundStyle(.secondary)
              Text("·")
                .foregroundStyle(.tertiary)
              Text("\(failedToolCount) 失败")
                .foregroundStyle(failedToolCount > 0 ? Color.red : Color.secondary)
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
              (failedToolCount > 0 ? Color.red : Color.secondary).opacity(0.10),
              in: Capsule()
            )
          }
          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if expanded {
        Divider()
          .opacity(0.55)
          .padding(.vertical, 9)
        VStack(alignment: .leading, spacing: 9) {
          ForEach(entries) { entry in
            ActivityEntryView(entry: entry, keepToolExpanded: shouldStayExpanded)
          }
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
    }
    .onAppear {
      if expansionStore?.values[expansionKey] == nil { expanded = shouldStayExpanded }
    }
    .onChange(of: shouldStayExpanded) { wasRunning, running in
      if running { expanded = true }
      if wasRunning && !running { expanded = false }
    }
  }

  @ViewBuilder
  private var activityStatusIcon: some View {
    if hasRunningActivity {
      ProgressView().controlSize(.mini)
    } else if taskIsRunning {
      Image(systemName: "ellipsis.circle")
        .foregroundStyle(.orange)
    } else {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(failedToolCount > 0 ? Color.orange : Color.green)
    }
  }

  private var activitySummary: String {
    if hasRunningActivity { return "正在处理" }
    if taskIsRunning { return "思考过程" }
    if toolCount == 0 { return "已完成思考" }
    return "已完成"
  }
}

private struct ActivityEntryView: View {
  let entry: ChatEntry
  let keepToolExpanded: Bool
  @Environment(\.conversationExpansionStore) private var expansionStore
  @State private var localExpanded = false

  private var expansionKey: String { "tool-\(entry.id)" }
  private var expanded: Bool {
    get { expansionStore?.values[expansionKey] ?? localExpanded }
    nonmutating set {
      localExpanded = newValue
      expansionStore?.values[expansionKey] = newValue
    }
  }

  var body: some View {
    Group {
      if entry.kind == .tool {
        VStack(alignment: .leading, spacing: 7) {
          Button {
            guard hasVisibleDetails else { return }
            withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
          } label: {
            HStack(alignment: .top, spacing: 9) {
              toolIcon
              VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                  Text(toolTitle).font(.caption.weight(.semibold))
                  if entry.isRunning { ProgressView().controlSize(.mini) }
                  if entry.isError {
                    Text("失败")
                      .font(.caption2.weight(.semibold))
                      .foregroundStyle(.red)
                  }
                }
                if let toolInput = entry.toolInput, !toolInput.isEmpty {
                  Text(toolInput)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.88))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
              }
              Spacer(minLength: 8)
              if hasVisibleDetails {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.tertiary)
                  .padding(.top, 2)
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)

          if expanded && hasVisibleDetails {
            activityContent
              .padding(.leading, 31)
          }
        }
        .padding(9)
        .background(toolBackground, in: RoundedRectangle(cornerRadius: 9))
      } else {
        VStack(alignment: .leading, spacing: 6) {
          activityHeader
          activityContent
        }
        .padding(.horizontal, 5)
      }
    }
    .onAppear {
      if entry.kind == .tool, expansionStore?.values[expansionKey] == nil {
        expanded = keepToolExpanded && entry.toolName != "bash" && entry.toolName != "read"
      }
    }
    .onChange(of: keepToolExpanded) { _, keepExpanded in
      guard entry.kind == .tool else { return }
      // bash output is secondary to the command and starts collapsed. Other tool
      // details stay visible while streaming; all nested disclosures reset when
      // the outer activity group folds after the turn settles.
      expanded = keepExpanded && entry.toolName != "bash" && entry.toolName != "read"
    }
  }

  private var activityHeader: some View {
    HStack(spacing: 7) {
      Image(systemName: activityIcon)
        .foregroundStyle(.secondary)
      Text(entry.title).font(.caption.weight(.medium))
      if entry.isRunning { ProgressView().controlSize(.mini) }
    }
    .foregroundStyle(entry.isError ? Color.red : Color.secondary)
  }

  private var toolIcon: some View {
    Image(systemName: activityIcon)
      .font(.caption.weight(.semibold))
      .foregroundStyle(entry.isError ? Color.red : toolColor)
      .frame(width: 22, height: 22)
      .background(
        (entry.isError ? Color.red : toolColor).opacity(0.11),
        in: RoundedRectangle(cornerRadius: 6)
      )
  }

  private var toolBackground: Color {
    entry.isError ? Color.red.opacity(0.035) : Color.secondary.opacity(0.035)
  }

  private var toolColor: Color {
    switch entry.toolName {
    case "bash": .blue
    case "read": .teal
    case "edit", "write": .orange
    case "web_search", "fetch_content", "source_check": .purple
    default: .secondary
    }
  }

  private var toolTitle: String {
    switch entry.toolName {
    case "bash": "运行命令"
    case "read": "读取文件"
    case "edit": "编辑文件"
    case "write": "写入文件"
    case "web_search": "搜索网页"
    case "fetch_content": "读取网页"
    case "source_check": "核查来源"
    case "generate_image": "生成图片"
    case let name?: name
    case nil: entry.title
    }
  }

  private var hasVisibleDetails: Bool {
    guard entry.toolName != "read" else { return false }
    return entry.diff?.isEmpty == false || !entry.text.isEmpty
  }

  @ViewBuilder
  private var activityContent: some View {
    if let diff = entry.diff, !diff.isEmpty {
      GitDiffView(diff: diff)
    } else if !entry.text.isEmpty, entry.kind != .tool {
      Text(entry.text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else if !entry.text.isEmpty {
      ScrollView([.horizontal, .vertical]) {
        Text(entry.text)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(9)
      }
      .frame(maxHeight: 300)
      .background(Color(nsColor: .textBackgroundColor).opacity(0.46))
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
      }
    }
  }

  private var activityIcon: String {
    switch entry.kind {
    case .thinking: "brain.head.profile"
    case .tool: "wrench.and.screwdriver"
    case .assistant: "sparkles"
    case .user: "person.crop.circle"
    case .compaction: "arrow.down.right.and.arrow.up.left"
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
  @State private var copied = false

  init(entry: ChatEntry, onEdit: (() -> Void)? = nil) {
    self.entry = entry
    self.onEdit = onEdit
    _expanded = State(
      initialValue: entry.kind != .thinking && entry.kind != .tool && entry.kind != .compaction
    )
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .foregroundStyle(color)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(entry.title).font(.caption.bold()).foregroundStyle(.secondary)
          if let model = entry.modelLabel {
            Text(model)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.secondary.opacity(0.10), in: Capsule())
          }
          if entry.isRunning { ProgressView().controlSize(.mini) }
          Spacer()
          if entry.kind == .assistant, !entry.text.isEmpty {
            Button(action: copyReply) {
              Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Color.green : Color.secondary)
            .help(copied ? "已复制" : "复制这条回复")
          }
          if let onEdit {
            Button(action: onEdit) {
              Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("重新编辑这条消息")
          }
        }
        if !entry.attachments.isEmpty {
          MessageAttachmentsView(attachments: entry.attachments)
        }
        if entry.kind == .tool || entry.kind == .thinking || entry.kind == .compaction {
          DisclosureGroup(isExpanded: $expanded) {
            if expanded { content.padding(.top, 5) }
          } label: {
            Text(disclosureLabel).font(.caption)
          }
        } else if !entry.text.isEmpty {
          content
        }
      }
      .padding(12)
      .background(background, in: RoundedRectangle(cornerRadius: 12))
      Spacer(minLength: entry.kind == .user ? 70 : 10)
    }
  }

  @ViewBuilder
  private var content: some View {
    if entry.kind == .tool || entry.kind == .thinking || entry.isRunning {
      // Parsing and laying out the entire growing Markdown document for every provider chunk is
      // expensive. Keep streaming output lightweight, then render Markdown once it is complete.
      Text(entry.text)
        .font(.system(.body, design: entry.kind == .tool ? .monospaced : .default))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      MarkdownView(entry.text)
        .font(.body)
    }
  }

  private func copyReply() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(entry.text, forType: .string)
    copied = true
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.5))
      copied = false
    }
  }

  private var summary: String {
    let firstLine = entry.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "暂无输出"
    return String(firstLine.prefix(90))
  }

  private var disclosureLabel: String {
    if expanded { return "收起详情" }
    if entry.kind == .compaction { return "查看压缩摘要" }
    return summary
  }

  private var icon: String {
    switch entry.kind {
    case .user: "person.crop.circle.fill"
    case .assistant: "sparkles"
    case .thinking: "brain.head.profile"
    case .tool: "wrench.and.screwdriver"
    case .compaction: "arrow.down.right.and.arrow.up.left"
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
    case .compaction: .teal
    case .system: .secondary
    }
  }

  private var background: Color {
    entry.kind == .user ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.07)
  }
}

private struct CodexAccountsView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var extensionUI: ExtensionUIModel
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
          .help("刷新额度")
          .disabled(app.isBusy)
          Button("管理") { app.openCodexAccountManager() }
            .buttonStyle(.plain)
            .font(.caption)
            .disabled(app.isBusy)
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
          if let updatedAt = extensionUI.codexAccountsUpdatedAt {
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
    if extensionUI.codexAccounts.isEmpty && extensionUI.geminiUsage == nil {
      emptyStatus
    } else {
      ScrollView {
        LazyVStack(spacing: 7) {
          ForEach(extensionUI.codexAccounts) { account in
            accountRow(account)
          }
          if let gemini = extensionUI.geminiUsage, gemini.isConfigured {
            geminiRow(gemini)
          }
        }
      }
      .frame(maxHeight: 240)
    }
  }

  @ViewBuilder
  private var currentAccount: some View {
    if let gemini = extensionUI.geminiUsage, gemini.isConfigured, gemini.isActive {
      geminiRow(gemini)
    } else if let account = extensionUI.codexAccounts.first(where: \.isActive) {
      accountRow(account)
    } else {
      emptyStatus
    }
  }

  private var emptyStatus: some View {
    Text(extensionUI.statuses["account-usage"] ?? "等待扩展提供账户信息…")
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
            .disabled(app.isBusy)
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
          HStack(spacing: 4) {
            Text(geminiWindowLabel(quota.window))
              .frame(width: 20, alignment: .leading)
            ProgressView(value: max(0, min(100, quota.remainingPercent)), total: 100)
              .tint(usageColor(quota.remainingPercent))
              .frame(minWidth: 24)
              .layoutPriority(1)
            Text("\(Int(quota.remainingPercent.rounded()))%")
              .monospacedDigit()
              .frame(width: 30, alignment: .trailing)
            if let resetAt = quota.resetAt {
              CompactResetTime(date: resetAt)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
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
    HStack(spacing: 4) {
      Text(label).frame(width: 20, alignment: .leading)
      ProgressView(value: max(0, min(100, window.remainingPercent)), total: 100)
        .tint(usageColor(window.remainingPercent))
        .frame(minWidth: 24)
        .layoutPriority(1)
      Text("\(Int(window.remainingPercent.rounded()))%")
        .monospacedDigit()
        .frame(width: 30, alignment: .trailing)
      if let resetAt = window.resetAt {
        CompactResetTime(date: resetAt)
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
  }

  private func windowLabel(_ window: CodexUsageWindow) -> String {
    guard let seconds = window.windowSeconds else { return "Q" }
    return seconds <= 21_600 ? "\(Int((seconds / 3_600).rounded()))H" : "7D"
  }

  private func geminiWindowLabel(_ window: String?) -> String {
    guard let window else { return "Q" }
    if window.localizedCaseInsensitiveContains("5h")
      || window.localizedCaseInsensitiveContains("5 hour")
    {
      return "5H"
    }
    if window.localizedCaseInsensitiveContains("7d")
      || window.localizedCaseInsensitiveContains("week")
    {
      return "7D"
    }
    return "Q"
  }

  private func usageColor(_ percent: Double) -> Color {
    if percent < 20 { return .red }
    if percent < 50 { return .orange }
    return .green
  }
}

private struct MessageAttachmentsView: View {
  let attachments: [PromptAttachment]
  @State private var previewedAttachment: PromptAttachment?

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(attachments) { attachment in
          if attachment.isImage, let image = NSImage(contentsOf: attachment.url) {
            Button {
              previewedAttachment = attachment
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Image(nsImage: image)
                  .resizable()
                  .scaledToFill()
                  .frame(width: 118, height: 82)
                  .clipped()
                  .clipShape(RoundedRectangle(cornerRadius: 7))
                Text(attachment.url.lastPathComponent)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
            .buttonStyle(.plain)
            .help("点击预览 \(attachment.url.lastPathComponent)")
          } else {
            Label(attachment.url.lastPathComponent, systemImage: "doc.fill")
              .font(.caption)
              .padding(8)
              .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
          }
        }
      }
    }
    .sheet(item: $previewedAttachment) { attachment in
      ImageAttachmentPreview(attachment: attachment)
    }
  }
}

private struct ImageAttachmentPreview: View {
  @Environment(\.dismiss) private var dismiss
  let attachment: PromptAttachment

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(attachment.url.lastPathComponent)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        Button("关闭") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(12)

      Divider()

      if let image = NSImage(contentsOf: attachment.url) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(16)
          .background(Color(nsColor: .windowBackgroundColor))
      } else {
        ContentUnavailableView("无法预览图片", systemImage: "photo.badge.exclamationmark")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 680)
  }
}

private struct ModelSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var app: AppModel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("模型与思考等级").font(.title2.bold())
          Text("显示设置写入 Pi 的 enabledModels；默认等级写入 modelThinkingLevels。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("完成") { dismiss() }
          .buttonStyle(.borderedProminent)
      }
      .padding(20)

      Divider()

      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text("压缩使用的模型").font(.callout.weight(.medium))
          Text("同时用于手动压缩和自动压缩；空闲时会在后台重新连接 Pi。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Picker(
          "压缩使用的模型",
          selection: Binding(
            get: { app.compactionModelID },
            set: { app.setCompactionModel($0) }
          )
        ) {
          Text("当前对话模型 · Current").tag(nil as String?)
          ForEach(app.allModels) { model in
            Text("\(model.name) · \(model.provider)").tag(Optional(model.id))
          }
        }
        .labelsHidden()
        .frame(width: 260)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)

      Divider()

      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(app.allModels) { model in
            modelRow(model)
            Divider()
          }
        }
        .padding(.horizontal, 20)
      }
    }
    .frame(width: 700, height: 560)
  }

  private func modelRow(_ model: PiModel) -> some View {
    HStack(spacing: 14) {
      Toggle(
        "",
        isOn: Binding(
          get: { app.models.contains(where: { $0.id == model.id }) },
          set: { app.setModelVisible($0, modelID: model.id) }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(model.name).font(.callout.weight(.medium))
          if model.id == app.selectedModelId {
            Text("当前")
              .font(.caption2)
              .foregroundStyle(Color.accentColor)
          }
        }
        Text(model.id)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }

      Spacer()

      Picker(
        "默认思考等级",
        selection: Binding(
          get: { app.modelDefaultThinkingLevels[model.id] ?? "__global__" },
          set: { value in
            app.setDefaultThinkingLevel(value == "__global__" ? nil : value, for: model.id)
          }
        )
      ) {
        Text("跟随全局 · Global").tag("__global__")
        ForEach(model.thinkingLevels, id: \.self) { level in
          Text(thinkingLevelLabel(level)).tag(level)
        }
      }
      .labelsHidden()
      .frame(width: 175)
    }
    .padding(.vertical, 11)
  }
}

private struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var path: String
  @StateObject private var versions: VersionManagerModel
  let projectURL: URL?
  let save: (String) -> Void

  init(path: String, projectURL: URL?, save: @escaping (String) -> Void) {
    _path = State(initialValue: path)
    _versions = StateObject(
      wrappedValue: VersionManagerModel(piPath: path, projectURL: projectURL))
    self.projectURL = projectURL
    self.save = save
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("设置").font(.title2.bold())
        Spacer()
        Button("完成") {
          save(path)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
      }
      .padding(20)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          GroupBox("Pi 可执行文件") {
            VStack(alignment: .leading, spacing: 8) {
              TextField("/path/to/pi", text: $path).textFieldStyle(.roundedBorder)
              Text("修改路径后保存并重新打开设置，即可检查对应的 Pi。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
          }

          GroupBox("Pi 版本") {
            HStack(spacing: 12) {
              versionIcon(hasUpdate: versions.piHasUpdate)
              VStack(alignment: .leading, spacing: 3) {
                Text("Pi coding agent").font(.headline)
                Text(versionDescription)
                  .font(.caption)
                  .foregroundStyle(versions.piHasUpdate ? Color.orange : Color.secondary)
              }
              Spacer()
              if versions.updatingID == "pi" {
                ProgressView().controlSize(.small)
              } else if versions.piHasUpdate {
                Button("更新到 \(versions.piLatestVersion ?? "最新版")") {
                  versions.updatePi()
                }
                .buttonStyle(.borderedProminent)
              }
            }
            .padding(.vertical, 5)
          }

          GroupBox("扩展包版本") {
            VStack(alignment: .leading, spacing: 0) {
              if versions.extensions.isEmpty, versions.isChecking {
                HStack(spacing: 8) {
                  ProgressView().controlSize(.small)
                  Text("正在读取扩展包并检查版本…")
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 12)
              } else if versions.extensions.isEmpty {
                Text("没有通过 Pi 包管理器安装的扩展包。")
                  .foregroundStyle(.secondary)
                  .padding(.vertical, 12)
              } else {
                ForEach(Array(versions.extensions.enumerated()), id: \.element.id) { index, item in
                  extensionRow(item)
                  if index < versions.extensions.count - 1 { Divider() }
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          if !versions.message.isEmpty {
            Text(versions.message)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .lineLimit(8)
          }
        }
        .padding(20)
      }

      Divider()
      HStack {
        Text("更新扩展后，需要重新打开会话才能载入新代码。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if versions.extensionUpdateCount > 0 {
          Button("更新全部扩展（\(versions.extensionUpdateCount)）") {
            versions.updateAllExtensions()
          }
          .disabled(versions.updatingID != nil || versions.isChecking)
        }
        Button {
          versions.refresh()
        } label: {
          if versions.isChecking {
            ProgressView().controlSize(.small)
          } else {
            Label("检查更新", systemImage: "arrow.clockwise")
          }
        }
        .disabled(versions.isChecking || versions.updatingID != nil)
      }
      .padding(16)
    }
    .frame(width: 650, height: 620)
    .onAppear { versions.refresh() }
  }

  private var versionDescription: String {
    guard let current = versions.piCurrentVersion else { return "尚未读取版本" }
    if versions.piHasUpdate { return "当前 \(current) · 最新 \(versions.piLatestVersion ?? "未知")" }
    if let latest = versions.piLatestVersion { return "当前 \(current) · 已是最新版本（\(latest)）" }
    return "当前 \(current) · 最新版本未知"
  }

  private func versionIcon(hasUpdate: Bool) -> some View {
    Image(systemName: hasUpdate ? "arrow.up.circle.fill" : "checkmark.circle.fill")
      .font(.title2)
      .foregroundStyle(hasUpdate ? Color.orange : Color.green)
  }

  private func extensionRow(_ item: ManagedExtension) -> some View {
    HStack(spacing: 11) {
      versionIcon(hasUpdate: item.hasUpdate)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(item.source).font(.callout.weight(.medium)).lineLimit(1)
          Text(item.scope)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
        }
        Text(extensionVersionDescription(item))
          .font(.caption)
          .foregroundStyle(item.hasUpdate ? Color.orange : Color.secondary)
        if let error = item.error, !error.isEmpty {
          Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
        }
      }
      Spacer()
      if versions.updatingID == item.id {
        ProgressView().controlSize(.small)
      } else if item.hasUpdate {
        Button("更新") { versions.update(item) }.buttonStyle(.borderedProminent)
      }
    }
    .padding(.vertical, 9)
  }

  private func extensionVersionDescription(_ item: ManagedExtension) -> String {
    let current = item.currentVersion ?? "未知"
    if item.isPinned {
      if let latest = item.latestVersion,
        VersionManagerModel.isNewer(latest, than: current)
      {
        return "当前 \(current) · 已固定版本 · Registry 最新 \(latest)"
      }
      return "当前 \(current) · 已固定版本，不参与自动更新"
    }
    if case .local = item.kind { return "本地扩展 · 不由 Pi 更新" }
    if item.hasUpdate { return "当前 \(current) · 最新 \(item.latestVersion ?? "未知")" }
    if let latest = item.latestVersion { return "当前 \(current) · 已是最新版本（\(latest)）" }
    return "当前 \(current) · 最新版本未知"
  }
}

private struct ExtensionDialogView: View {
  @EnvironmentObject private var extensionUI: ExtensionUIModel
  let dialog: ExtensionDialog
  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(dialog.title).font(.headline)
      switch dialog.kind {
      case .select(let options):
        ForEach(options, id: \.self) { option in
          Button(option) { extensionUI.answerDialog(value: option) }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      case .confirm(let message):
        Text(message)
        HStack {
          Button("取消") { extensionUI.answerDialog(confirmed: false) }
          Button("确认") { extensionUI.answerDialog(confirmed: true) }
            .buttonStyle(.borderedProminent)
        }
      case .input(_, let placeholder, let multiline):
        if multiline {
          TextEditor(text: $text).frame(minHeight: 180)
        } else {
          TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
        }
        HStack {
          Button("取消") { extensionUI.answerDialog(cancelled: true) }
          Button("提交") { extensionUI.answerDialog(value: text) }
            .buttonStyle(.borderedProminent)
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

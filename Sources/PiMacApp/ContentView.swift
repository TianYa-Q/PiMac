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

private enum MainPage {
  case conversation
  case usage
}

private enum ConversationLayout {
  static let contentInset: CGFloat = 20
  static let bottomAnchorID = "conversation-bottom"
}

/// SwiftUI does not expose scroll phases on macOS 14. Observe AppKit's live-scroll
/// notifications so content growth is never mistaken for a user's scroll gesture.
private struct ConversationScrollObserver: NSViewRepresentable {
  let onUserScroll: (_ isAtBottom: Bool) -> Void

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
    var onUserScroll: (Bool) -> Void
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []

    init(onUserScroll: @escaping (Bool) -> Void) {
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

      observers.append(
        NotificationCenter.default.addObserver(
          forName: NSScrollView.willStartLiveScrollNotification,
          object: scrollView,
          queue: .main
        ) { [weak self] _ in
          self?.onUserScroll(false)
        })
      for name in [
        NSScrollView.didLiveScrollNotification,
        NSScrollView.didEndLiveScrollNotification,
      ] {
        observers.append(
          NotificationCenter.default.addObserver(
            forName: name,
            object: scrollView,
            queue: .main
          ) { [weak self, weak scrollView] _ in
            guard let self, let scrollView else { return }
            self.onUserScroll(Self.isAtBottom(scrollView))
          })
      }
    }

    private static func isAtBottom(_ scrollView: NSScrollView) -> Bool {
      guard let documentView = scrollView.documentView else { return true }
      let visible = scrollView.contentView.documentVisibleRect
      let document = documentView.bounds
      let tolerance: CGFloat = 2
      if scrollView.contentView.isFlipped {
        return visible.maxY >= document.maxY - tolerance
      }
      return visible.minY <= document.minY + tolerance
    }
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
  @State private var renamingProject: WorkspaceProject?
  @State private var projectNameDraft = ""
  @State private var showingProjectRename = false
  @State private var choosingSession = false
  @State private var choosingAttachments = false
  @State private var showingSettings = false
  @State private var showingModelSettings = false
  @State private var showingScheduledTasks = false
  @State private var gitContext: GitWorkspaceContext?
  @State private var selectedPage: MainPage = .conversation
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
  @State private var sessionSearchText = ""
  @State private var sessionSearchExpanded = false
  @FocusState private var sessionSearchFocused: Bool
  @State private var sessionSearchResults: [SessionSearchResult] = []
  @State private var isSearchingSessions = false
  @State private var sessionSearchError: String?
  @State private var sessionSearchRetry = UUID()
  @AppStorage("projectsCollapsed") private var projectsCollapsed = false
  @AppStorage(SidebarWidth.storageKey) private var sidebarWidth = SidebarWidth.defaultValue
  @GestureState private var sidebarDragTranslation: CGFloat = 0

  var body: some View {
    HStack(spacing: 0) {
      redesignedSidebar
        .frame(
          width: SidebarWidth.clamped(
            SidebarWidth.clamped(sidebarWidth) + Double(sidebarDragTranslation)))

      Divider()
        .frame(width: 1)
        .overlay {
          Color.clear
            .frame(width: 10)
            .contentShape(Rectangle())
            .gesture(
              DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($sidebarDragTranslation) { value, translation, _ in
                  translation = value.translation.width
                }
                .onEnded { value in
                  sidebarWidth = SidebarWidth.clamped(
                    SidebarWidth.clamped(sidebarWidth) + Double(value.translation.width))
                }
            )
            .onHover { hovering in
              (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
            .help("拖动调整侧栏宽度，调整后自动保存")
            .accessibilityLabel("侧栏宽度")
            .accessibilityValue("\(Int(SidebarWidth.clamped(sidebarWidth)))")
            .accessibilityAdjustableAction { direction in
              switch direction {
              case .increment: sidebarWidth = SidebarWidth.clamped(sidebarWidth + 10)
              case .decrement: sidebarWidth = SidebarWidth.clamped(sidebarWidth - 10)
              @unknown default: break
              }
            }
        }

      ZStack {
        VStack(spacing: 0) {
          conversation
          Divider()
          composer
        }
        // Keep the AppKit-backed conversation alive while viewing usage so returning to the
        // task preserves its scroll position and editor selection.
        .opacity(selectedPage == .conversation ? 1 : 0)
        .allowsHitTesting(selectedPage == .conversation)
        .accessibilityHidden(selectedPage != .conversation)

        if selectedPage == .usage {
          UsageDashboardView()
            .transition(.opacity)
        }
      }
      // Keep this subtree alive across task changes. Re-keying even only the detail pane tears
      // down its AppKit-backed scroll/editor views; because the sidebar uses translucent
      // material, that teardown is visible as a flash across the entire left column. Per-task
      // transient state is reset explicitly in the tabID change handler below instead.
      .frame(minWidth: 680, minHeight: 560)
    }
    .alert("重命名项目", isPresented: $showingProjectRename) {
      TextField("项目名称", text: $projectNameDraft)
      Button("取消", role: .cancel) { renamingProject = nil }
      Button("保存") {
        if let project = renamingProject {
          workspace.renameProject(project, to: projectNameDraft)
        }
        renamingProject = nil
      }
      .disabled(projectNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    } message: {
      Text("仅修改显示名称，不会更改项目目录或会话。")
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
      SettingsView(
        path: app.piPath, projectURL: app.projectURL, telegram: workspace.telegram,
        workspace: workspace
      ) {
        app.piPath = $0
      }
    }
    .sheet(isPresented: $showingScheduledTasks) {
      ScheduledTasksView(workspace: workspace)
    }
    .sheet(item: $gitContext) { context in
      GitWorkspaceView(store: workspace.git, server: workspace.server, context: context)
    }
    .sheet(isPresented: $showingModelSettings) {
      ModelSettingsView()
        .environmentObject(app)
    }
    .sheet(item: $previewedAttachment) { attachment in
      ImageAttachmentPreview(attachment: attachment)
    }
    .sheet(
      item: Binding(
        get: { extensionUI.dialog.map { ExtensionDialogPresentation(dialog: $0) } },
        set: { _ in }  // Requests are dismissed only by reconciliation or an explicit answer.
      )
    ) { presentation in
      ExtensionDialogView(dialog: presentation.dialog)
        .id(presentation.id)
        .interactiveDismissDisabled()
    }
    .onChange(of: app.connectionState) {
      if case .connected = app.connectionState {
        composerFocused = true
      }
    }
    .onChange(of: app.projectURL?.standardizedFileURL.path) {
      visibleSessionCount = 10
      sessionSearchText = ""
      sessionSearchResults = []
      sessionSearchExpanded = false
      sessionSearchFocused = false
    }
    .onChange(of: sessionSearchFocused) {
      if sessionSearchFocused { composerFocused = false }
    }
    .onChange(of: sessionSearchText) {
      isSearchingSessions = !SessionSearchQuery(sessionSearchText).isEmpty
      sessionSearchResults = []
      sessionSearchError = nil
    }
    .task(id: sessionSearchKey) {
      let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !SessionSearchQuery(query).isEmpty else {
        sessionSearchResults = []
        sessionSearchError = nil
        isSearchingSessions = false
        return
      }
      isSearchingSessions = true
      sessionSearchError = nil
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      let sessions = allSessions
      let messagesByPath: [String: [String]]
      do {
        messagesByPath = try await workspace.server.sessionSearchMessages(
          query: query, sessions: sessions)
      } catch {
        guard !Task.isCancelled else { return }
        sessionSearchResults = []
        isSearchingSessions = false
        sessionSearchError = "无法读取 Server 会话，请检查连接后重新搜索。"
        return
      }
      let search = Task.detached(priority: .userInitiated) {
        SessionSearch.results(for: query, in: sessions, messagesByPath: messagesByPath)
      }
      let results = await withTaskCancellationHandler {
        await search.value
      } onCancel: {
        search.cancel()
      }
      guard !Task.isCancelled else { return }
      sessionSearchResults = results
      isSearchingSessions = false
    }
    .onChange(of: tabID) {
      app.refreshModelPreferences()
      composerSelection = NSRange(location: 0, length: 0)
      conversationScrollMode = .pinnedToBottom
      autoScrollScheduled = false
      autoScrollGeneration += 1
      initialSessionScrollPending = true
      conversationBottomIsVisible = false
      previewedAttachment = nil
    }
  }

  private var redesignedSidebar: some View {
    let sessions = allSessions
    let visibleSessions = Array(sessions.prefix(visibleSessionCount))
    let searching = !SessionSearchQuery(sessionSearchText).isEmpty
    return VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 9) {
          Image(systemName: "terminal")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8))
          Text("Pi Mac")
            .font(.system(size: 16, weight: .bold, design: .rounded))
          ServerConnectionBadge(server: workspace.server)
          Spacer(minLength: 0)
          Button {
            showingScheduledTasks = true
          } label: {
            Image(systemName: "calendar.badge.clock")
              .font(.system(size: 15, weight: .medium))
              .frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("定时任务")
          .accessibilityLabel("定时任务")
          Button {
            showingSettings = true
          } label: {
            Image(systemName: "gearshape")
              .font(.system(size: 15, weight: .medium))
              .frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("设置")
          .accessibilityLabel("设置")
        }
        .padding(.bottom, 12)

        HStack(spacing: 4) {
          mainPageButton(.conversation, title: "对话", icon: "bubble.left.and.bubble.right")
          mainPageButton(.usage, title: "用量", icon: "chart.bar.xaxis")
        }
        .padding(4)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 12)

        HStack(spacing: 6) {
          Text("项目")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text("\(workspace.projects.count)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
          Spacer()
          if !workspace.projects.isEmpty {
            Button {
              withAnimation(.easeInOut(duration: 0.16)) {
                projectsCollapsed.toggle()
              }
            } label: {
              Image(systemName: projectsCollapsed ? "list.bullet" : "square.grid.2x2")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(projectsCollapsed ? "展开项目列表" : "折叠为图标")
            .accessibilityLabel(projectsCollapsed ? "展开项目列表" : "折叠为图标")
          }
          Button {
            choosingProject = true
          } label: {
            Image(systemName: "plus")
              .frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("添加项目")
          .accessibilityLabel("添加项目")
        }
        .foregroundStyle(.secondary)
        .padding(.bottom, 3)

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
            HStack(spacing: 9) {
              Image(systemName: "square.and.pencil")
                .font(.system(size: 14, weight: .semibold))
              Text("新聊天")
                .font(.callout.weight(.semibold))
              Spacer()
              Image(systemName: "plus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor.opacity(0.65))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
          }
          .buttonStyle(.plain)
          .help("在当前项目新建聊天")
          .padding(.top, 8)
          .padding(.bottom, 10)

          HStack {
            Text("会话")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            Spacer()
            Button {
              if sessionSearchExpanded {
                closeSessionSearch()
              } else {
                sessionSearchExpanded = true
                sessionSearchFocused = true
              }
            } label: {
              Image(systemName: sessionSearchExpanded ? "xmark" : "magnifyingglass")
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help(sessionSearchExpanded ? "关闭搜索（⇧⌘F）" : "搜索聊天记录（⇧⌘F）")
            .accessibilityLabel(sessionSearchExpanded ? "关闭搜索" : "搜索聊天记录")
          }

          if sessionSearchExpanded {
            SessionSearchField(
              text: $sessionSearchText, focused: $sessionSearchFocused,
              onClose: closeSessionSearch,
              onSubmit: {
                guard !isSearchingSessions, let result = sessionSearchResults.first,
                  let projectURL = app.projectURL
                else { return }
                workspace.openSession(path: result.session.path, in: projectURL)
              }
            )
          }

          if searching {
            if isSearchingSessions {
              ProgressView("正在搜索…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else if let searchError = sessionSearchError {
              VStack(alignment: .leading, spacing: 8) {
                Label(searchError, systemImage: "exclamationmark.triangle")
                  .foregroundStyle(.secondary)
                Button("重试搜索", systemImage: "arrow.clockwise") {
                  sessionSearchError = nil
                  isSearchingSessions = true
                  sessionSearchRetry = UUID()
                }
                .buttonStyle(.bordered)
              }
              .font(.caption)
              .padding(.vertical, 8)
            } else if sessionSearchResults.isEmpty {
              ContentUnavailableView.search(text: sessionSearchText)
                .controlSize(.small)
            } else {
              Text("找到 \(sessionSearchResults.count) 个会话 · 回车打开首项")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
              ScrollView {
                LazyVStack(spacing: 3) {
                  ForEach(sessionSearchResults) { result in
                    redesignedSessionRow(result.session, snippet: result.snippet)
                  }
                }
                .padding(.vertical, 6)
              }
            }
          } else if visibleSessions.isEmpty, let projectURL = app.projectURL,
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
                if visibleSessions.count < sessions.count {
                  loadMoreSessionsButton(totalCount: sessions.count)
                }
              }
              .padding(.vertical, 6)
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

  private func closeSessionSearch() {
    sessionSearchFocused = false
    sessionSearchText = ""
    sessionSearchExpanded = false
  }

  private func mainPageButton(_ page: MainPage, title: String, icon: String) -> some View {
    Button {
      withAnimation(.easeOut(duration: 0.14)) { selectedPage = page }
    } label: {
      Label(title, systemImage: icon)
        .font(.callout.weight(selectedPage == page ? .semibold : .medium))
        .foregroundStyle(selectedPage == page ? Color.primary : Color.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(
          selectedPage == page ? Color(nsColor: .controlBackgroundColor) : Color.clear,
          in: RoundedRectangle(cornerRadius: 9)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private func projectNameMenu(_ project: WorkspaceProject) -> some View {
    Button("重命名…", systemImage: "pencil") {
      renamingProject = project
      projectNameDraft = project.name
      showingProjectRename = true
    }
    if project.name != project.url.lastPathComponent {
      Button("恢复目录名") {
        workspace.renameProject(project, to: project.url.lastPathComponent)
      }
    }
  }

  private func compactProjectButton(_ project: WorkspaceProject) -> some View {
    let selected = workspace.selectedProject?.id == project.id
    return Button {
      workspace.selectProject(project)
    } label: {
      projectIcon(project, size: 30)
        .padding(3)
        .background(
          selected ? Color.accentColor.opacity(0.13) : Color.clear,
          in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        }
    }
    .buttonStyle(.plain)
    .help(project.name)
    .contextMenu {
      projectNameMenu(project)
      Divider()
      Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
      Divider()
      Button("从列表移除", role: .destructive) { workspace.removeProject(project) }
    }
  }

  private func projectIcon(_ project: WorkspaceProject, size: CGFloat) -> some View {
    let palette: [Color] = [
      .teal, .indigo, .orange, .green, .purple, .blue,
    ]
    let scalarTotal = project.name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    let color = palette[scalarTotal % palette.count]
    let initial = String(project.name.prefix(1)).uppercased()
    return ZStack {
      RoundedRectangle(cornerRadius: size * 0.26)
        .fill(color.opacity(0.2))
      Text(initial)
        .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
        .foregroundStyle(color)
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
      projectNameMenu(project)
      Divider()
      Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
      Divider()
      Button("从列表移除", role: .destructive) { workspace.removeProject(project) }
    }
  }

  private var sessionSearchKey: String {
    let sessions = allSessions
    return
      "\(app.projectURL?.standardizedFileURL.path ?? "")|\(sessionSearchText)|\(sessionSearchRetry)|"
      + sessions.map { "\($0.path)|\($0.title)|\($0.modifiedAt.timeIntervalSince1970)" }
      .joined(separator: "\n")
  }

  private func redesignedSessionRow(_ session: SessionItem, snippet: String? = nil) -> some View {
    let selected = workspace.isSelectedSession(path: session.path)
    let running = workspace.model(forSessionPath: session.path)?.isBusy == true
    return SidebarHoverRegion { hovered in
      ZStack(alignment: .trailing) {
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
              if let snippet {
                Text(snippet)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
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
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(.secondary)
              .frame(width: 26, height: 26)
              .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
          }
          .buttonStyle(.plain)
          .disabled(running)
          .help(running ? "任务运行时不能归档" : "归档会话")
          .padding(.trailing, 6)
          .transition(.opacity)
        }
      }
      .background {
        RoundedRectangle(cornerRadius: 9)
          .fill(
            selected
              ? Color.accentColor.opacity(0.11)
              : hovered ? Color.primary.opacity(0.055) : Color.clear
          )
          .overlay {
            RoundedRectangle(cornerRadius: 9)
              .strokeBorder(
                hovered
                  ? (selected ? Color.accentColor.opacity(0.17) : Color.primary.opacity(0.07))
                  : Color.clear,
                lineWidth: 1
              )
          }
          .shadow(color: .black.opacity(hovered ? 0.07 : 0), radius: 4, y: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 9))
    }
  }

  private var sidebar: some View {
    let sessions = allSessions
    let visibleSessions = Array(sessions.prefix(visibleSessionCount))
    return VStack(alignment: .leading, spacing: 16) {
      Label("Pi Mac", systemImage: "apple.terminal")
        .font(.title2.bold())

      HStack(spacing: 7) {
        Circle().fill(app.connectionState.color).frame(width: 8, height: 8)
        Text("Pi \(app.connectionState.label)").font(.caption)
      }
      TelegramConnectionBadge(control: workspace.telegram)

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
                  if visibleSessions.count < sessions.count {
                    loadMoreSessionsButton(totalCount: sessions.count)
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
          if let cost = stats.cost { Text(cost, format: .currency(code: "USD")) }
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

  private func loadMoreSessionsButton(totalCount: Int) -> some View {
    Button {
      visibleSessionCount = min(visibleSessionCount + 10, totalCount)
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
    let turns = app.conversationTurns

    return GeometryReader { viewport in
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
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

            if app.isStreaming && app.streamActivity.phase != nil {
              streamActivityIndicator
            }

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
            ConversationScrollObserver(onUserScroll: updateScrollModeAfterUserScroll)
              .frame(width: 0, height: 0)
          }
        }
        .coordinateSpace(name: "conversation-scroll")
        .scrollIndicators(.hidden)
        .overlay(alignment: .bottomTrailing) {
          if conversationScrollMode == .manual && !conversationBottomIsVisible && !turns.isEmpty {
            Button {
              initialScrollGeneration += 1
              initialSessionScrollPending = false
              autoScrollGeneration += 1
              autoScrollScheduled = false
              conversationScrollMode = .pinnedToBottom
              proxy.scrollTo(ConversationLayout.bottomAnchorID, anchor: .bottom)
            } label: {
              Label(app.isStreaming ? "跟随输出" : "回到最新", systemImage: "arrow.down")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .help("滚动到最新消息并恢复自动跟随")
            .accessibilityLabel("回到最新消息")
            .padding(16)
          }
        }
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
        .onChange(of: tabID) {
          // Switching projects replaces the environment AppModel while preserving this ScrollView.
          // The two projects can temporarily expose the same/empty session path, so path changes
          // alone are not a reliable trigger for the initial bottom positioning.
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

  private var streamActivityIndicator: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let status = app.streamActivity.label(at: context.date) ?? ""
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
          .frame(width: 18, height: 18)
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel(status)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
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
    // Appending a prompt rebuilds the turn array. Preserve unchanged Markdown/AppKit text
    // subtrees so earlier messages are not briefly cleared and redrawn.
    .equatable()
    .id(turn.id)
  }

  private func scheduleInitialSessionScroll(_ proxy: ScrollViewProxy) {
    initialScrollGeneration += 1
    let generation = initialScrollGeneration

    // RPC 返回、VStack 创建子视图以及 Markdown 定高并不在同一轮布局中。
    // 等布局稳定后再执行最终定位；若期间消息继续到达，旧任务会自动失效。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
      guard generation == initialScrollGeneration, !app.messages.isEmpty else { return }
      // 会话切换时 preference 可能仍短暂携带上一个会话的“底部可见”值，不能用它
      // 决定是否定位。首次稳定布局后始终滚到新会话底部；每次切换只执行一次。
      proxy.scrollTo(ConversationLayout.bottomAnchorID, anchor: .bottom)
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

  private func updateScrollModeAfterUserScroll(isAtBottom: Bool) {
    // Replacing a project's transcript makes AppKit emit transient scroll notifications while
    // the new content is being laid out. They are not user intent and must not cancel the
    // pending one-shot scroll to the new session's bottom.
    guard !initialSessionScrollPending else { return }

    if isAtBottom {
      // AppKit's end-of-scroll notification can arrive after the geometry preference update.
      // Re-pin directly so returning to the bottom always resumes following new output.
      conversationScrollMode = .pinnedToBottom
      return
    }

    conversationScrollMode = .manual
    autoScrollGeneration += 1
    autoScrollScheduled = false

    // 用户操作优先于会话打开后的延迟定位。
    initialScrollGeneration += 1
    initialSessionScrollPending = false
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
        .modifier(ComposerControlChrome())
        .help("添加图片或文件")
        .accessibilityLabel("添加图片或文件")
        modelMenu
        thinkingMenu
        if app.supportsFastMode {
          Button {
            app.changeFastMode(to: !app.fastModeEnabled)
          } label: {
            Label("Fast", systemImage: app.fastModeEnabled ? "bolt.fill" : "bolt")
              .font(.caption)
              .foregroundStyle(app.fastModeEnabled ? Color.orange : Color.secondary)
          }
          .buttonStyle(.plain)
          .modifier(ComposerControlChrome())
          .disabled(!app.canRestartSafely || !app.fastModeAvailable)
          .help("下一次请求使用 OpenAI / Codex 优先处理（可能消耗更多额度）；不改变思考等级")
          .accessibilityValue(app.fastModeEnabled ? "开启" : "关闭")
        }
        Button(action: app.compact) {
          Label("压缩", systemImage: "arrow.down.right.and.arrow.up.left")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .modifier(ComposerControlChrome())
        .disabled(app.isBusy)
        .help("压缩上下文")
        ComposerGitButton(server: workspace.server, hasProject: app.projectURL != nil) {
          guard let cwd = workspace.selectedGitDirectory else { return }
          gitContext = GitWorkspaceContext(
            cwd: cwd, threadID: app.threadID,
            projectID: app.projectURL.flatMap { workspace.server.projectID(for: $0) })
        }
        Spacer(minLength: 8)
        let promptIsEmpty =
          app.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && app.attachments.isEmpty
        if app.isStreaming {
          Button {
            sendPromptFollowingOutput(delivery: .steer)
          } label: {
            Label("工具后插入", systemImage: "arrow.turn.down.right")
          }.buttonStyle(.borderedProminent)
            .disabled(promptIsEmpty || !app.canSubmitPrompt)
            .help("当前轮工具调用完成后、下一次模型请求前插入（Enter）")
          Button {
            sendPromptFollowingOutput(delivery: .followUp)
          } label: {
            Label("排队发送", systemImage: "clock")
          }.buttonStyle(.bordered)
            .disabled(promptIsEmpty || !app.canSubmitPrompt)
            .help("当前任务结束后发送（Option+Enter）")
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
      .controlSize(.small)

      // Session switching clears stats before the new RPC result arrives. Keep the footer
      // mounted, with the same height for metrics and loading status, so controls don't jump.
      Rectangle()
        .fill(Color.primary.opacity(0.06))
        .frame(height: 1)
      HStack(spacing: 12) {
        ScrollView(.horizontal, showsIndicators: false) {
          sessionMetrics
        }
        .frame(height: 18)
        if !workspace.developmentReloadStatus.isEmpty {
          Text(workspace.developmentReloadStatus)
            .font(.caption).foregroundStyle(.orange).lineLimit(1)
            .help(workspace.developmentReloadStatus)
        }
        if !app.statusText.isEmpty {
          if app.showsStatusProgress {
            ProgressView().controlSize(.small)
              .frame(width: 18, height: 18)
          }
          Text(app.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(app.statusText)
            .accessibilityLabel(app.statusText)
        }
      }
      .frame(height: 18)
      .padding(.horizontal, 2)
      .padding(.vertical, 2)
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
        app.moveQueuedPrompt(id: prompt.id, direction: -1)
      } label: {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .disabled(app.queuedPromptMoveTarget(id: prompt.id, direction: -1) == nil)
      .help("上移（同一发送时机）")
      .accessibilityLabel("上移待发送消息")

      Button {
        app.moveQueuedPrompt(id: prompt.id, direction: 1)
      } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .disabled(app.queuedPromptMoveTarget(id: prompt.id, direction: 1) == nil)
      .help("下移（同一发送时机）")
      .accessibilityLabel("下移待发送消息")

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
    .menuIndicator(.hidden)
    .fixedSize()
    .modifier(ComposerControlChrome())
  }

  private var sessionMetrics: some View {
    HStack(spacing: 12) {
      if let speed = app.outputTokensPerSecond {
        Text("输出 \(speed, specifier: "%.1f") tokens/s")
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .help("当前任务输出 tokens ÷ 模型请求耗时（含思考与首字等待，不含工具执行）。每次模型响应结束更新。")
      } else {
        Text("输出 -- tokens/s")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("等待模型返回实际 token 用量")
      }
      Divider().frame(height: 12)
      if let stats = app.stats {
        HStack(spacing: 12) {
          Text(stats.contextPercent.map { "上下文 \(Int($0))%" } ?? "上下文 --")
            .foregroundStyle(contextUsageColor(stats.contextPercent))
          Text(
            stats.contextWindow.map {
              "\(stats.totalTokens.formatted()) / \($0.formatted()) tokens"
            } ?? "\(stats.totalTokens.formatted()) tokens")
          Text(stats.cacheHitPercent.map { "缓存命中 \(Int($0.rounded()))%" } ?? "缓存命中 --")
          if let cost = stats.cost { Text(cost, format: .currency(code: "USD")) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      } else {
        Text("上下文 -- · -- / -- tokens · 缓存命中 --")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("等待 Provider 返回上下文和 token 用量")
      }
    }
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
      Divider()
      Button("将当前等级设为全局默认") {
        app.setGlobalDefaultThinkingLevel(app.selectedThinkingLevel)
      }
      Text("全局默认：\(thinkingLevelLabel(app.globalDefaultThinkingLevel))")
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "brain.head.profile")
        Text(thinkingLevelLabel(app.selectedThinkingLevel))
        Image(systemName: "chevron.down").font(.caption2)
      }
      .font(.caption)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .modifier(ComposerControlChrome())
    .disabled(app.isBusy)
  }

}

/// Connection updates stay local instead of invalidating the transcript.
private struct ServerConnectionBadge: View {
  @ObservedObject var server: T3DesktopClient

  var body: some View {
    Image(systemName: server.isConnected ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
      .font(.system(size: 12))
      .foregroundStyle(server.isConnected ? Color.green : Color.orange)
      .help(server.status)
      .accessibilityLabel("Server 连接状态：\(server.status)")
  }
}

private struct ComposerGitButton: View {
  @ObservedObject var server: T3DesktopClient
  let hasProject: Bool
  let openGit: () -> Void

  var body: some View {
    Button(action: openGit) {
      Label("Git", systemImage: "arrow.triangle.branch").font(.caption)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .modifier(ComposerControlChrome())
    .disabled(!hasProject || !server.isConnected)
    .help("查看当前线程工作区的分支与变更")
    .accessibilityLabel("源代码管理")
  }
}

/// Lightweight toolbar affordance without native button bezels or menu accents.
private struct ComposerControlChrome: ViewModifier {
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(
        Color.primary.opacity(isHovered && isEnabled ? 0.08 : 0.025),
        in: RoundedRectangle(cornerRadius: 6)
      )
      .contentShape(RoundedRectangle(cornerRadius: 6))
      .onHover { isHovered = $0 }
  }
}

/// Hover is local to the row, not ContentView (which also lays out the transcript).
private struct TelegramConnectionBadge: View {
  @ObservedObject var control: TelegramControl

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(control.enabled ? control.connectionState.color : Color.secondary)
        .frame(width: 6, height: 6)
      Text("Telegram").foregroundStyle(.primary)
      Text(
        control.enabled
          ? (control.connectionState == .connected ? "在线" : "离线") : "未启用"
      )
      .foregroundStyle(.secondary)
    }
    .font(.caption2.weight(.medium))
    .lineLimit(1)
    .help(control.status)
    .accessibilityLabel(
      "Telegram \(control.enabled ? control.connectionState.label : "未启用")")
  }
}

private struct SidebarHoverRegion<Content: View>: View {
  @State private var hovered = false
  @ViewBuilder var content: (Bool) -> Content

  var body: some View {
    content(hovered)
      .onHover { hovered = $0 }
      .animation(.easeOut(duration: 0.12), value: hovered)
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
      // Focus can move to another editor before this async request runs (e.g. the search box).
      // Never reclaim it based on an outdated SwiftUI update.
      DispatchQueue.main.async { [weak textView, weak coordinator = context.coordinator] in
        guard let textView, coordinator?.isFocused == true,
          let window = textView.window, window.firstResponder !== textView,
          !(window.firstResponder is NSTextView)
        else { return }
        window.makeFirstResponder(textView)
      }
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
      // AppKit may ask every view to handle a key equivalent. Only intercept paste when
      // this editor is actually the first responder; otherwise ⌘V belongs to the search field.
      guard window?.firstResponder === self else { return false }
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

private struct ConversationTurnView: View, Equatable {
  let turn: ConversationTurn
  let isActive: Bool
  let onEdit: (String) -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    // `onEdit` is recreated with ContentView's body but has the same behavior. Comparing only
    // render inputs lets SwiftUI retain completed turns when a new prompt is appended.
    lhs.turn == rhs.turn && lhs.isActive == rhs.isActive
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let user = turn.user {
        ChatEntryView(entry: user) { onEdit(user.text) }
          .equatable()
          .id(user.id)
      }
      if !turn.activity.isEmpty {
        ActivityGroupView(entries: turn.activity, taskIsRunning: isActive)
      }
      if let assistant = turn.finalAssistant {
        ChatEntryView(entry: assistant)
          .equatable()
          .id(assistant.id)
      }
      ForEach(turn.supplementaryEntries) { entry in
        ChatEntryView(entry: entry)
          .equatable()
          .id(entry.id)
      }
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
      if entry.kind == .tool || entry.kind == .thinking {
        VStack(alignment: .leading, spacing: 7) {
          Button {
            guard hasVisibleDetails else { return }
            withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
          } label: {
            HStack(alignment: .top, spacing: 9) {
              toolIcon
              VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                  Text(entry.kind == .thinking ? "思考过程" : toolTitle)
                    .font(.caption.weight(.semibold))
                  if entry.isRunning { ProgressView().controlSize(.mini) }
                  if entry.isError {
                    Text("失败")
                      .font(.caption2.weight(.semibold))
                      .foregroundStyle(.red)
                  }
                }
                if entry.kind == .tool, let toolInput = entry.toolInput, !toolInput.isEmpty {
                  if entry.toolName == "read" {
                    ReadToolInputView(input: toolInput)
                  } else if entry.toolName == "codemode" {
                    HStack(spacing: 6) {
                      Text("JavaScript · \(toolInput.components(separatedBy: "\n").count) 行")
                      if nestedCallCount > 0 {
                        Text("· \(nestedCallCount) 次嵌套调用")
                      }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  } else {
                    Text(toolInput)
                      .font(.system(.caption, design: .monospaced))
                      .lineLimit(3)
                      .foregroundStyle(.primary.opacity(0.88))
                      .fixedSize(horizontal: false, vertical: true)
                      .frame(maxWidth: .infinity, alignment: .leading)
                  }
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
            if entry.toolName == "codemode", let code = entry.toolInput,
              !code.isEmpty
            {
              ToolDetailView(title: "脚本 · JavaScript", text: code)
                .padding(.leading, 31)
            }
            activityContent
              .padding(.leading, 31)
            if !entry.attachments.isEmpty {
              MessageAttachmentsView(attachments: entry.attachments)
                .padding(.leading, 31)
            }
            ForEach(entry.childToolEntries) { child in
              AnyView(ActivityEntryView(entry: child, keepToolExpanded: keepToolExpanded))
                .padding(.leading, 31)
            }
            ForEach(metadataOnlyCalls) { call in
              VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                  Image(systemName: "arrow.turn.down.right")
                  Text(call.name).fontWeight(.semibold)
                  if call.status == "unfinished" { Text("未完成").foregroundStyle(.secondary) }
                  if call.status == "error" { Text("失败").foregroundStyle(.red) }
                  if let duration = call.durationMs {
                    Text("\(Int(duration)) ms").foregroundStyle(.secondary)
                  }
                }
                if let input = call.input {
                  if call.name == "read" {
                    ReadToolInputView(input: input)
                  } else {
                    Text(input).lineLimit(3).textSelection(.enabled).help(input)
                  }
                }
                if let error = call.error {
                  Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
              }
              .font(.system(.caption, design: .monospaced))
              .padding(.leading, 31)
            }
            if !entry.nestedCallsComplete {
              Text("嵌套调用记录不完整（Pi 已截断或有未完成调用）")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 31)
            }
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
      if expansionStore?.values[expansionKey] == nil {
        if entry.kind == .thinking {
          expanded = true
        } else if entry.kind == .tool {
          expanded = keepToolExpanded && entry.toolName != "bash" && entry.toolName != "read"
        }
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

  private var metadataOnlyCalls: [NestedToolCall] {
    entry.nestedCalls.filter { call in
      !entry.childToolEntries.contains { $0.id.hasSuffix(":\(call.id)") }
    }
  }

  private var nestedCallCount: Int { entry.childToolEntries.count + metadataOnlyCalls.count }

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
    if entry.kind == .thinking { return .orange }
    return switch entry.toolName {
    case "bash": .blue
    case "read": .teal
    case "edit", "write": .orange
    case "codemode": .indigo
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
    case "codemode": "Code Mode · 执行脚本"
    case "web_search": "搜索网页"
    case "fetch_content": "读取网页"
    case "source_check": "核查来源"
    case "generate_image": "生成图片"
    case let name?: name
    case nil: entry.title
    }
  }

  private var hasVisibleDetails: Bool {
    if entry.kind == .thinking { return !entry.text.isEmpty }
    if !entry.attachments.isEmpty { return true }
    if entry.toolName == "codemode", entry.toolInput?.isEmpty == false { return true }
    if !entry.childToolEntries.isEmpty || !entry.nestedCalls.isEmpty || !entry.nestedCallsComplete {
      return true
    }
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
      ToolDetailView(
        title: entry.isError ? "错误输出" : (entry.toolName == "read" ? "文件内容" : "输出"),
        text: entry.text
      )
    }
  }

  private var activityIcon: String {
    switch entry.kind {
    case .thinking: "brain.head.profile"
    case .tool:
      switch entry.toolName {
      case "codemode": "curlybraces"
      case "read": "doc.text"
      case "bash": "terminal"
      case "edit", "write": "square.and.pencil"
      default: "wrench.and.screwdriver"
      }
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

private struct ChatEntryView: View, Equatable {
  let entry: ChatEntry
  let onEdit: (() -> Void)?
  @State private var expanded: Bool
  @State private var copied = false

  static func == (lhs: Self, rhs: Self) -> Bool {
    // The edit closure is recreated whenever ContentView updates, but its behavior is tied to
    // the stable entry ID. Ignore it so an unchanged message keeps its rendered text subtree.
    lhs.entry == rhs.entry
  }

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
          if let timestamp = entry.timestamp {
            Text(timestamp.formatted(date: .omitted, time: .standard))
              .font(.caption2)
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .help(timestamp.formatted(date: .complete, time: .standard))
          }
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
        .fixedSize(horizontal: false, vertical: true)
    } else {
      MarkdownView(entry.text)
        .equatable()
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
  @State private var search = ""
  @State private var onlyVisible = false

  private var filteredModels: [PiModel] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let visibleIDs = Set(app.models.map(\.id))
    return app.allModels.filter { model in
      (!onlyVisible || visibleIDs.contains(model.id))
        && (query.isEmpty || "\(model.name) \(model.id)".localizedCaseInsensitiveContains(query))
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "slider.horizontal.3")
          .font(.title2)
          .foregroundStyle(Color.accentColor)
          .frame(width: 40, height: 40)
          .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        VStack(alignment: .leading, spacing: 4) {
          Text("模型与思考等级").font(.title2.bold())
          Text("设置新会话默认值，管理模型显示与思考等级")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button(action: app.reloadModelList) {
          Label("刷新", systemImage: "arrow.clockwise")
        }
        .disabled(!app.canReloadModelList || app.isLoadingConfiguration)
        .help("重新读取 Server 的可用模型列表")
        Button("完成") { dismiss() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 18)
      .background(Color(nsColor: .windowBackgroundColor))

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 10) {
            sectionTitle("会话默认值", icon: "bubble.left.and.bubble.right")
            VStack(spacing: 0) {
              settingRow("默认模型", detail: "仅用于新会话，不改变已有会话。") {
                Picker(
                  "默认模型",
                  selection: Binding(
                    get: { app.defaultModelID },
                    set: { app.setDefaultModel($0) }
                  )
                ) {
                  Text("自动选择").tag(nil as String?)
                  if let id = app.defaultModelID, !app.models.contains(where: { $0.id == id }) {
                    Text("\(id)（隐藏或不可用）").tag(Optional(id))
                  }
                  ForEach(app.models) { model in
                    Text("\(model.name) · \(model.provider)").tag(Optional(model.id))
                  }
                }
                .labelsHidden()
              }
              Divider().padding(.horizontal, 16)
              settingRow("默认思考等级", detail: "模型未设置专属等级时使用。") {
                Picker(
                  "默认思考等级",
                  selection: Binding(
                    get: { app.globalDefaultThinkingLevel },
                    set: { app.setGlobalDefaultThinkingLevel($0) }
                  )
                ) {
                  ForEach(PiModel.thinkingLevelOrder, id: \.self) { level in
                    Text(thinkingLevelLabel(level)).tag(level)
                  }
                }
                .labelsHidden()
              }
            }
            .background(
              Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
          }

          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
              .foregroundStyle(Color.accentColor)
              .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
              Text("上下文压缩").font(.caption.weight(.semibold))
              Text("使用 /compact 命令，压缩模型与自动压缩策略遵循 Pi 配置。")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
          }
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

          VStack(alignment: .leading, spacing: 10) {
            HStack {
              sectionTitle("可用模型", icon: "square.stack.3d.up")
              Spacer()
              Text("已显示 \(app.models.count) / \(app.allModels.count)")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08), in: Capsule())
            }
            HStack(spacing: 8) {
              Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
              TextField("搜索模型名称或提供商", text: $search)
                .textFieldStyle(.plain)
              if !search.isEmpty {
                Button {
                  search = ""
                } label: {
                  Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
              }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
              Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            HStack {
              Toggle("仅已显示", isOn: $onlyVisible)
                .toggleStyle(.checkbox)
                .help("只查看已在对话选择列表中显示的模型")
              Spacer()
              Text("默认思考等级")
                .frame(width: 150, alignment: .trailing)
            }
            .font(.caption).foregroundStyle(.secondary)

            LazyVStack(spacing: 0) {
              if filteredModels.isEmpty {
                Text(app.allModels.isEmpty ? "暂无模型，请连接 Server 后刷新。" : "没有匹配的模型")
                  .foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity).padding(24)
              }
              ForEach(filteredModels) { model in
                modelRow(model)
                if model.id != filteredModels.last?.id {
                  Divider().padding(.leading, 62).padding(.trailing, 14)
                }
              }
            }
            .background(
              Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
          }
        }
        .padding(24)
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(width: 780, height: 720)
  }

  private func sectionTitle(_ title: String, icon: String) -> some View {
    Label(title, systemImage: icon)
      .font(.callout.weight(.semibold))
      .foregroundStyle(.primary)
  }

  private func settingRow<Control: View>(
    _ title: String, detail: String, @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(spacing: 20) {
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.callout.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      control()
        .pickerStyle(.menu)
        .controlSize(.regular)
        .frame(width: 260)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private func modelRow(_ model: PiModel) -> some View {
    HStack(spacing: 12) {
      Toggle(
        "显示 \(model.name)",
        isOn: Binding(
          get: { app.models.contains(where: { $0.id == model.id }) },
          set: { app.setModelVisible($0, modelID: model.id) }
        )
      )
      .labelsHidden().toggleStyle(.switch).controlSize(.small)
      .help("在对话模型列表中显示此模型")

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(model.name).font(.callout.weight(.medium))
            .lineLimit(1)
            .help(model.name)
          if model.id == app.selectedModelId {
            Text("当前").font(.caption2)
              .foregroundStyle(Color.accentColor)
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(Color.accentColor.opacity(0.12), in: Capsule())
          }
        }
        Text(model.id).font(.caption.monospaced())
          .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          .help(model.id)
      }
      Spacer(minLength: 8)
      Picker(
        "专属默认思考等级",
        selection: Binding(
          get: { app.modelDefaultThinkingLevels[model.id] ?? "__global__" },
          set: { app.setDefaultThinkingLevel($0 == "__global__" ? nil : $0, for: model.id) }
        )
      ) {
        Text("跟随全局").tag("__global__")
        ForEach(model.thinkingLevels, id: \.self) { level in
          Text(thinkingLevelLabel(level)).tag(level)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .controlSize(.small)
      .frame(width: 150)
      .help("仅用于此模型的新会话；跟随全局时使用默认思考等级")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }
}

private struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var path: String
  private let originalPath: String
  @State private var selectedTab: SettingsTab = .runtime
  @StateObject private var versions: VersionManagerModel
  @State private var extensionSource = ""
  @State private var installLocally = false
  @State private var extensionToRemove: ManagedExtension?

  private enum SettingsTab: String, CaseIterable {
    case runtime = "运行环境"
    case mobile = "手机连接"
    case telegram = "Telegram"
    case updates = "版本与扩展"

    var icon: String {
      switch self {
      case .runtime: return "desktopcomputer"
      case .mobile: return "iphone"
      case .telegram: return "paperplane"
      case .updates: return "shippingbox"
      }
    }

  }
  let projectURL: URL?
  let telegram: TelegramControl
  let workspace: WorkspaceModel
  let save: (String) -> Void

  init(
    path: String, projectURL: URL?, telegram: TelegramControl, workspace: WorkspaceModel,
    save: @escaping (String) -> Void
  ) {
    _path = State(initialValue: path)
    originalPath = path
    _versions = StateObject(
      wrappedValue: VersionManagerModel(piPath: path, projectURL: projectURL))
    self.projectURL = projectURL
    self.telegram = telegram
    self.workspace = workspace
    self.save = save
  }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      VStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            if selectedTab == .runtime {
              LidSleepSettingsView()

              GroupBox("Pi 路径") {
                VStack(alignment: .leading, spacing: 8) {
                  HStack(spacing: 8) {
                    TextField("pi 或完整路径", text: $path)
                      .textFieldStyle(.roundedBorder)
                    Button("选择…", action: choosePiExecutable)
                    if pathChanged {
                      Button("还原") { path = originalPath }
                        .buttonStyle(.borderless)
                    }
                  }
                  if normalizedPath.isEmpty {
                    Label("Pi 路径不能为空", systemImage: "exclamationmark.circle")
                      .font(.caption).foregroundStyle(.red)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
              }

            }

            if selectedTab == .mobile {
              T3SettingsView(service: workspace.t3Bridge, workspace: workspace)
            }
            if selectedTab == .telegram {
              TelegramSettingsView(control: telegram)
            }

            if selectedTab == .updates {
              GroupBox("Pi 版本") {
                HStack(spacing: 12) {
                  versionIcon(
                    hasUpdate: versions.piHasUpdate,
                    verified: versions.piCurrentVersion != nil && versions.piLatestVersion != nil)
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
                    .disabled(versions.isBusy)
                  }
                }
                .padding(.vertical, 5)
              }

              GroupBox("安装扩展包") {
                VStack(alignment: .leading, spacing: 8) {
                  TextField("npm:包名、git:仓库地址或本地路径", text: $extensionSource)
                    .textFieldStyle(.roundedBorder)
                    .disabled(versions.isBusy)
                  HStack {
                    Picker("安装范围", selection: $installLocally) {
                      Text("全局").tag(false)
                      Text("当前项目").tag(true)
                        .disabled(projectURL == nil)
                    }
                    .frame(maxWidth: 280)
                    .disabled(versions.isBusy)
                    Spacer()
                    Button {
                      versions.install(source: extensionSource, local: installLocally)
                    } label: {
                      if versions.updatingID == "install" {
                        ProgressView().controlSize(.small)
                      } else {
                        Label("安装", systemImage: "plus")
                      }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                      versions.isBusy
                        || VersionManagerModel.installArguments(
                          source: extensionSource, local: installLocally) == nil
                        || (installLocally && projectURL == nil))
                  }
                }
                .padding(.vertical, 5)
              }

              GroupBox("已安装扩展包") {
                VStack(alignment: .leading, spacing: 0) {
                  if versions.extensions.isEmpty, versions.isChecking {
                    HStack(spacing: 8) {
                      ProgressView().controlSize(.small)
                      Text("检查中…")
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                  } else if versions.extensions.isEmpty {
                    Text("暂无扩展")
                      .foregroundStyle(.secondary)
                      .padding(.vertical, 12)
                  } else {
                    ForEach(Array(versions.extensions.enumerated()), id: \.element.id) {
                      index, item in
                      extensionRow(item)
                      if index < versions.extensions.count - 1 { Divider() }
                    }
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }

              Text("扩展变更后需重开会话。")
                .font(.caption).foregroundStyle(.secondary)

              if !versions.message.isEmpty {
                Text(versions.message)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
                  .lineLimit(8)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(24)
        }
        .id(selectedTab)
        .background(Color.primary.opacity(0.02))

        Divider()
        HStack(spacing: 10) {
          if selectedTab == .updates {
            Button {
              versions.refresh()
            } label: {
              if versions.isChecking {
                ProgressView().controlSize(.small)
              } else {
                Text("检查更新")
              }
            }
            .disabled(versions.isBusy)
            if versions.extensionUpdateCount > 0 {
              Button("更新全部（\(versions.extensionUpdateCount)）") {
                versions.updateAllExtensions()
              }
              .disabled(versions.isBusy)
            }
          }
          if pathChanged {
            Text("路径待保存")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button(pathChanged ? "保存并关闭" : "关闭") {
            save(normalizedPath)
            dismiss()
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(normalizedPath.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
      }
    }
    .frame(width: 760, height: 580)
    .onAppear { versions.refresh() }
    .alert(
      "删除扩展包？",
      isPresented: Binding(
        get: { extensionToRemove != nil },
        set: { if !$0 { extensionToRemove = nil } }
      )
    ) {
      Button("取消", role: .cancel) { extensionToRemove = nil }
      Button("删除", role: .destructive) {
        if let item = extensionToRemove { versions.remove(item) }
        extensionToRemove = nil
      }
    } message: {
      if let item = extensionToRemove {
        Text("将从\(item.scope)配置中移除 \(item.source)。本地源文件不会被删除，已打开的会话不受影响。")
      }
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("设置").font(.title2.bold())
        .padding(.horizontal, 12).padding(.top, 8)
      VStack(spacing: 5) {
        ForEach(SettingsTab.allCases, id: \.self) { tab in
          Button {
            selectedTab = tab
          } label: {
            HStack(spacing: 10) {
              Image(systemName: tab.icon).frame(width: 20)
              Text(tab.rawValue).font(.callout.weight(selectedTab == tab ? .semibold : .regular))
              Spacer(minLength: 0)
            }
            .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(
              selectedTab == tab ? Color.accentColor.opacity(0.10) : Color.clear,
              in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
        }
      }
      Spacer()
    }
    .padding(12)
    .frame(width: 156)
    .frame(maxHeight: .infinity)
    .background(.regularMaterial)
  }

  private var normalizedPath: String {
    path.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var pathChanged: Bool { normalizedPath != originalPath }

  private func choosePiExecutable() {
    let panel = NSOpenPanel()
    panel.title = "选择 Pi 可执行文件"
    panel.message = "请选择已安装的 Pi 命令或可执行文件。"
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    if panel.runModal() == .OK, let url = panel.url {
      path = url.path
    }
  }

  private var versionDescription: String {
    guard let current = versions.piCurrentVersion else {
      return versions.isChecking ? "正在检查版本…" : "尚未读取版本"
    }
    if versions.piHasUpdate { return "当前 \(current) · 最新 \(versions.piLatestVersion ?? "未知")" }
    if let latest = versions.piLatestVersion { return "当前 \(current) · 已是最新版本（\(latest)）" }
    return "当前 \(current) · 最新版本未知"
  }

  private func versionIcon(hasUpdate: Bool, verified: Bool) -> some View {
    Image(
      systemName: hasUpdate
        ? "arrow.up.circle.fill" : (verified ? "checkmark.circle.fill" : "shippingbox")
    )
    .font(.title2)
    .foregroundStyle(hasUpdate ? Color.orange : (verified ? Color.green : Color.secondary))
  }

  private func extensionRow(_ item: ManagedExtension) -> some View {
    HStack(spacing: 11) {
      versionIcon(
        hasUpdate: item.hasUpdate,
        verified: item.error == nil && item.currentVersion != nil && item.latestVersion != nil)
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
      } else {
        if item.hasUpdate {
          Button("更新") { versions.update(item) }
            .buttonStyle(.borderedProminent)
            .disabled(versions.isBusy)
        }
        Button(role: .destructive) {
          extensionToRemove = item
        } label: {
          Image(systemName: "trash")
        }
        .help("删除扩展包")
        .accessibilityLabel("删除 \(item.source)")
        .disabled(versions.isBusy)
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

extension AppModel {
  fileprivate var clientConnected: Bool {
    if case .connected = connectionState { return true }
    return false
  }
}

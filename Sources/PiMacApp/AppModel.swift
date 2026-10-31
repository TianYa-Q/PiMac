import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// Presentation state for one T3 thread. No Pi process, RPC transport or file writer.
@MainActor
final class AppModel: ObservableObject {
  let browserPreview = BrowserPreviewModel()
  @Published var connectionState: ConnectionState = .disconnected
  @Published var projectURL: URL?
  @Published var messages: [ChatEntry] = [] {
    didSet {
      // 较早的工具结果也会原位更新，不能只按条数或末条消息判断失效。
      conversationTimelineCache = nil
    }
  }
  private var conversationTimelineCache:
    (children: [ConversationSubagent], snapshot: ConversationTimelineSnapshot)?
  var conversationTurns: [ConversationTurn] { ConversationTurn.group(messages) }

  func conversationTimeline(children: [ConversationSubagent]) -> ConversationTimelineSnapshot {
    if let cache = conversationTimelineCache, cache.children == children {
      return cache.snapshot
    }
    let snapshot = ConversationTimelineSnapshot(messages: messages, children: children)
    conversationTimelineCache = (children, snapshot)
    return snapshot
  }
  @Published var models: [PiModel] = []
  @Published var allModels: [PiModel] = []
  @Published var modelDefaultThinkingLevels: [String: String] = [:]
  @Published var globalDefaultThinkingLevel = "medium"
  @Published var defaultModelID: String? = UserDefaults.standard.string(
    forKey: "defaultNewSessionModelID")
  @Published var selectedModelId = ""
  @Published var thinkingLevels = PiModel.thinkingLevelOrder
  @Published var selectedThinkingLevel = "medium"
  @Published private(set) var fastModeEnabled = false
  @Published private(set) var fastModeAvailable = false
  @Published private(set) var isChangingFastMode = false
  @Published private(set) var outputTokensPerSecond: Double?
  @Published private(set) var streamActivity = StreamActivity()
  @Published private(set) var codexRotationInFlight = false
  @Published private var isManagingSessionAccounts = false
  var isManagingAccounts: Bool { isManagingSessionAccounts || accountWorkspace != nil }
  @Published private(set) var accountWorkspace: AccountWorkspaceModel?
  private var extensionUIEpoch = ""
  private var extensionUISerial = 0
  private var answeredDialogIDs: Set<String> = []
  @Published private(set) var awaitingAgentStart = false
  @Published private(set) var lastSettledTurnID: String?
  private(set) var terminalStopReason: String?
  @Published var isStreaming = false
  @Published var isCompacting = false
  @Published var isLoadingConfiguration = false
  @Published private(set) var goalState: ThreadGoal.State = .none
  @Published private(set) var isShowingCachedConversation = false
  @Published var sessionName = ""
  @Published var sessions: [SessionItem] = []
  /// Compatibility name for UI/TG metadata; contains t3:<thread-id>, NEVER a file path.
  @Published var currentSessionPath = ""
  @Published var stats: SessionStats?
  @Published var composerText = ""
  @Published var attachments: [PromptAttachment] = []
  /// Server 队列与尚未确认的本地提交分开保存；确认后按消息 ID 原位交接。
  @Published private var serverQueuedPrompts: [ServerQueuedPrompt] = []
  private var pendingQueuedMessages: [ChatEntry] {
    deliveryRecords.filter { $0.delivery == .followUp && $0.state != .draft }.map(\.entry)
  }
  private let deliveryUpdates = PassthroughSubject<Void, Never>()
  var queuedPromptUpdates: AnyPublisher<Void, Never> {
    Publishers.Merge(
      $serverQueuedPrompts.map { _ in () }, deliveryUpdates.eraseToAnyPublisher()
    ).eraseToAnyPublisher()
  }
  var queuedPrompts: [ServerQueuedPrompt] {
    serverQueuedPrompts
      + pendingQueuedMessages.map {
        ServerQueuedPrompt(
          id: "pending:\($0.id)", text: $0.text, attachments: $0.attachments,
          submissionState: $0.isError ? .unconfirmed : .submitting)
      }
  }
  @Published private(set) var queueHeld = false
  @Published var statusText = "" {
    didSet {
      transientStatusTask?.cancel()
      statusRevision = UUID()
    }
  }
  private var statusRevision = UUID()
  private(set) var transientStatusTask: Task<Void, Never>?
  @Published var diagnosticText = ""
  weak var extensionUI: ExtensionUIModel?
  var onTelegramLifecycleEvent: ((String) -> Void)?
  private weak var server: T3DesktopClient?
  private var serverConnectionObservation: AnyCancellable?
  private let observerID = UUID()
  private var isConversationVisible = true
  private var conversationConsumers: Set<UUID> = []
  private var needsConversationUpdates: Bool {
    isConversationVisible || !conversationConsumers.isEmpty
  }

  func setConversationVisible(_ visible: Bool) {
    isConversationVisible = visible
    server?.setWatchVisibility(owner: observerID, visible: needsConversationUpdates)
  }

  /// Telegram 等真实消费者可独立持有观察租约；不能因隐藏桌面标签而丢失远程回复。
  func setConversationConsumer(_ owner: UUID, active: Bool) {
    if active { conversationConsumers.insert(owner) } else { conversationConsumers.remove(owner) }
    server?.setWatchVisibility(owner: observerID, visible: needsConversationUpdates)
  }

  /// 隐藏标签只消费轻量 shell 状态，不能拿空正文覆盖已经显示的历史。
  func applyBackgroundThreadState(_ thread: [String: Any]) {
    guard !needsConversationUpdates, thread["id"] as? String == threadID else { return }
    applyRunState(thread)
    sessionName = thread["title"] as? String ?? sessionName
  }
  private(set) var skillWorkspaceContext: WorkspaceSkillContext?

  func enterSkillWorkspace() {
    guard let skillWorkspaceContext else { return }
    server?.enterSkillWorkspace(owner: observerID, context: skillWorkspaceContext)
  }
  private var connectTask: Task<Void, Never>?
  private var generation = UUID()
  @Published private var submitting = false
  @Published private(set) var isStopping = false
  @Published private(set) var pendingQueueCancellations: Set<String> = []
  private var submissionTask: Task<Void, Never>?
  private(set) var deliveryCoordinator: MessageRecoveryCoordinator?
  private var pendingSentMessages: [ChatEntry] {
    deliveryRecords.filter { $0.delivery == .steer && $0.state != .draft }.map(\.entry)
  }
  private var pendingSelection: [String: Any]?
  private var submittedFromTurnID: String?
  private var lastTurnID: String?
  private var lastTurnState: String?
  private var pendingThreadPath: String?
  private var modelPreferenceKey = "defaultNewSessionModelID"
  private var speed = OutputSpeedTracker()
  private var accountStatusTask: Task<Void, Never>?
  private var accountQuotaRefreshPolicy = AccountQuotaRefreshPolicy()
  private var accountSelectionLastPoll: ContinuousClock.Instant?
  var threadID: String? { Self.threadID(from: currentSessionPath) }

  var piPath: String {
    get { UserDefaults.standard.string(forKey: "piPath") ?? Self.suggestedPiPath() }
    set {
      guard newValue != piPath else { return }
      UserDefaults.standard.set(newValue, forKey: "piPath")
      showTransientStatus("Pi Provider 路径已保存，重启本机 Server 后生效")
      objectWillChange.send()
    }
  }
  /// A replacement status invalidates the timer, even when its text is identical.
  @discardableResult
  func showTransientStatus(_ text: String, duration: Duration = .seconds(5)) -> Task<Void, Never> {
    statusText = text
    let revision = statusRevision
    let task = Task { [weak self] in
      do {
        try await Task.sleep(for: duration)
        try Task.checkCancellation()
      } catch { return }
      guard let self, self.statusRevision == revision else { return }
      self.statusText = ""
    }
    transientStatusTask = task
    return task
  }

  var showsStatusProgress: Bool { isBusy || isLoadingConfiguration }
  var isProcessRunning: Bool { server?.isConnected == true && threadID != nil }
  var isBusy: Bool {
    isStreaming || isCompacting || submitting || isStopping || isCheckingDelivery
      || !pendingQueueCancellations.isEmpty
      || deliveryCoordinator?.activeThreads.contains(threadID ?? "") == true || awaitingAgentStart
      || pendingSelection != nil
      || codexRotationInFlight || isChangingFastMode || isManagingAccounts
      || extensionUI?.hasPendingDialog(for: self) == true
  }
  var canRestartSafely: Bool {
    !isBusy && !isLoadingConfiguration && queuedPrompts.isEmpty && recoveryRecords.isEmpty
      && deliveryStorageFailure == nil
  }
  var canReloadModelList: Bool { server?.isConnected == true && !isBusy }
  var modelContextWindows: [String: Int] { server?.modelContextWindows ?? [:] }
  private let disconnectedTextGenerationModels = TextGenerationModelStore()
  var textGenerationModels: TextGenerationModelStore {
    server?.textGenerationModels ?? disconnectedTextGenerationModels
  }
  var canConfigureTextGenerationModel: Bool { server?.isConnected == true }
  func updateTextGenerationModel(_ modelID: String?) async {
    guard let server else { return }
    await server.updateTextGenerationModel(modelID)
  }
  var promptSubmissionUnavailableReason: String? {
    guard server?.isConnected == true else {
      return "暂时无法发送：\(server?.status ?? "T3 Server 尚未连接")；草稿已保留"
    }
    if isLoadingConfiguration { return "正在加载会话配置，请稍后发送" }
    guard connectionState == .connected else { return "会话尚未就绪，请重新打开聊天" }
    if isStopping { return "正在停止当前任务，请稍后发送" }
    if isCompacting { return "正在压缩上下文，请完成后发送" }
    if codexRotationInFlight { return "正在切换账号，请稍后发送" }
    if submitting || deliveryCoordinator?.activeThreads.contains(threadID ?? "") == true {
      return "正在处理上一条投递，请稍后发送"
    }
    if deliveryCoordinator?.store.isReadOnly == true {
      return "发件箱记录无法读取，请先处理保存错误；草稿已保留"
    }
    // 历史待恢复输入只约束它自身的重试，不能锁住独立的新消息；
    // 真实进行中的投递仍由上面的线程锁串行保护，旧记录不会随新提交自动重发。
    if awaitingAgentStart { return "正在等待 Server 确认任务启动，请稍后发送" }
    if pendingSelection != nil { return "正在保存模型设置，请稍后发送" }
    if isManagingAccounts { return "请先完成账号管理操作" }
    if extensionUI?.hasPendingDialog(for: self) == true { return "请先处理会话中的交互请求" }
    return nil
  }
  var canSubmitPrompt: Bool { promptSubmissionUnavailableReason == nil }
  var goalCreationUnavailableReason: String? {
    if isBusy { return "会话正在执行或等待交互，请空闲后创建目标" }
    guard canSubmitPrompt else { return "会话尚未就绪，请连接后再创建目标" }
    guard projectURL != nil else { return "请先选择项目" }
    guard !selectedModelId.isEmpty else { return "请先选择模型" }
    return nil
  }
  var canReuseProcessForNewSession: Bool { false }  // A tab is a view, not a process pool slot.
  /// 仅供列表补齐尚未进入 Server shell 的本地提交，不持久化另一份会话目录。
  var locallySubmittedSession: SessionItem? {
    guard let entry = pendingSentMessages.first ?? pendingQueuedMessages.first,
      !currentSessionPath.isEmpty
    else { return nil }
    let title = String(entry.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    return SessionItem(
      path: currentSessionPath, title: title.isEmpty ? "附件消息" : title,
      modifiedAt: entry.timestamp ?? .now)
  }
  var hasUserMessage: Bool { messages.contains { $0.kind == .user } }
  var hasUnsubmittedInput: Bool {
    !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
  }
  var supportsFastMode: Bool { fastModeAvailable }
  @Published var accountQuotaMessage = ""
  @Published private(set) var isRefreshingAccountQuota = false
  var canManageAccounts: Bool {
    AccountManagementAccess.canOpen(
      hasAvailableSession: server?.isConnected == true
        && (accountUsageProvider == .chatGPT || accountUsageProvider == .legacyCodex),
      isLoadingConfiguration: isLoadingConfiguration,
      isAlreadyPresenting: isManagingAccounts
        || extensionUI?.hasPendingDialog(for: self) == true)
  }
  var supportsAccountSwitch: Bool {
    isProcessRunning && (accountUsageProvider == .chatGPT || accountUsageProvider == .legacyCodex)
  }
  var supportsAccountRotation: Bool { false }
  var accountUsageProvider: AccountUsageProvider? { AccountUsageProvider(modelID: selectedModelId) }
  var remotePendingMessages: [ChatEntry] { [] }

  init(
    startupProjectURL: URL? = nil, continueLastSession: Bool = true,
    startupSessionPath: String? = nil, restoreLastProjectOnLaunch: Bool = true,
    initialComposerText: String = "", remembersDesktopProject: Bool = true,
    modelPreferenceKey: String = "defaultNewSessionModelID", thinkingPreferenceKey: String? = nil
  ) {
    globalDefaultThinkingLevel =
      UserDefaults.standard.string(forKey: "t3DefaultThinkingLevel") ?? "medium"
    modelDefaultThinkingLevels =
      UserDefaults.standard.dictionary(forKey: "t3ModelDefaultThinkingLevels") as? [String: String]
      ?? [:]
    selectedThinkingLevel = globalDefaultThinkingLevel
    projectURL = startupProjectURL?.standardizedFileURL
    pendingThreadPath = startupSessionPath
    composerText = initialComposerText
    self.modelPreferenceKey = modelPreferenceKey
    defaultModelID = Self.preferredNewSessionModelID(
      currentModelID: "", preferenceKey: modelPreferenceKey)
    if let thinkingPreferenceKey,
      let level = UserDefaults.standard.string(forKey: thinkingPreferenceKey)
    {
      selectedThinkingLevel = level
    }
  }

  func attach(to server: T3DesktopClient, deliveries: MessageRecoveryCoordinator? = nil) {
    self.server = server
    let coordinator =
      deliveries ?? MessageRecoveryCoordinator(store: MessageOutboxStore(), transport: server)
    deliveryCoordinator = coordinator
    deliveryObservation = coordinator.store.$messages.combineLatest(coordinator.store.$failure)
      .sink { [weak self] _, _ in
        Task { @MainActor [weak self] in self?.refreshDeliveryPresentation() }
      }
    // 设置页也可在断线/重连时保持打开；不能依赖会话消息变化才刷新可编辑状态。
    serverConnectionObservation = server.$isConnected.combineLatest(server.$status)
      .sink { [weak self, weak server] ready, _ in
        self?.objectWillChange.send()
        guard ready else { return }
        // @Published 的回调早于属性写入；下一轮再检查真实连接，避免读取到旧值。
        // 仅恢复打开失败的视图，不重置运行中的会话，更不会重放任何提交命令。
        Task { @MainActor [weak self, weak server] in
          guard let self, server?.isConnected == true else { return }
          self.refreshModels()
          if case .failed = self.connectionState, let project = self.projectURL {
            self.open(project: project, path: self.pendingThreadPath)
          }
        }
      }
    if let projectURL { open(project: projectURL, path: pendingThreadPath) }
  }
  func connect(to projectURL: URL, continueLastSession: Bool = true) {
    open(project: projectURL, path: nil)
  }
  private func open(project: URL, path: String?, completion: ((Bool) -> Void)? = nil) {
    closeAccountWorkspace()
    extensionUI?.removeRequests(from: self)
    extensionUIEpoch = ""
    extensionUISerial = 0
    answeredDialogIDs.removeAll()
    isManagingSessionAccounts = false
    serverQueuedPrompts.removeAll()
    goalState = .none
    displayedOutboxIDs = []
    isCheckingDelivery = false
    recoveryReady = false
    recoveryChecked = false
    submissionTask = nil
    submitting = false
    isStopping = false
    pendingQueueCancellations = []
    awaitingAgentStart = false
    connectTask?.cancel()
    server?.unwatch(owner: observerID)
    generation = UUID()
    pendingSelection = nil
    stats = nil
    let current = generation
    let changingSession =
      currentSessionPath != (path ?? "")
      || projectURL != project.standardizedFileURL
    projectURL = project.standardizedFileURL
    skillWorkspaceContext = WorkspaceSkillContext(
      instanceID: "pi", projectCwd: project.standardizedFileURL.path,
      threadID: path.flatMap { Self.threadID(from: $0) })
    enterSkillWorkspace()
    pendingThreadPath = path
    if changingSession {
      messages = []
      sessionName = ""
      isStreaming = false
      isCompacting = false
      isShowingCachedConversation = false
    }
    currentSessionPath = path ?? ""
    if let projectURL, let id = threadID,
      let cached = server?.conversationCache.snapshot(project: projectURL, threadID: id),
      changingSession || messages.isEmpty
    {
      // 不能通过 apply 恢复：它会把旧快照标成已连接，并触发交互/发件箱确认。
      messages = cached.messages
      sessionName = cached.title
      isShowingCachedConversation = true
    }
    refreshDeliveryPresentation()
    // 已连接时的新聊天只是本地草稿，无须再排队等待一次异步连接流程。
    // 仍使用实时模型目录校验，不能把磁盘缓存当作发送许可。
    if path == nil, server?.isConnected == true {
      refreshModels()
      if !selectedModelId.isEmpty {
        currentSessionPath = ""
        connectionState = .connected
        isLoadingConfiguration = false
        statusText = ""
        completion?(true)
        return
      }
    }
    connectionState = .connecting
    isLoadingConfiguration = true
    statusText = isShowingCachedConversation ? "正在后台核对会话…" : "正在连接 T3 线程…"
    connectTask = Task { [weak self] in
      guard let self, let server = self.server else {
        completion?(false)
        return
      }
      do {
        try await server.waitUntilReady()
        try Task.checkCancellation()
        self.refreshModels()
        if let path {
          // waitUntilReady 已取得本次连接的实时列表；打开已有会话不再刷新全量列表，
          // 也不创建项目。转录/附件在 watch 内独立核对，不阻塞输入。
          guard self.generation == current, !Task.isCancelled else { return }
          guard let projectID = server.projectID(for: project),
            let target = Self.threadID(from: path), let thread = server.thread(target),
            thread["projectId"] as? String == projectID
          else {
            throw T3DesktopClient.ClientError.rejected
          }
          self.observeThread(target, on: server)
        } else {
          // 新聊天仅准备本地输入和模型选项；首次发送前不创建 Server 会话。
          guard !self.selectedModelId.isEmpty else { throw T3DesktopClient.ClientError.rejected }
          self.currentSessionPath = ""
        }
        guard self.generation == current, !Task.isCancelled else { return }
        self.pendingThreadPath = nil
        self.connectionState = .connected
        self.isLoadingConfiguration = false
        self.statusText = self.isShowingCachedConversation ? "正在后台核对会话…" : ""
        completion?(true)
      } catch {
        guard self.generation == current else { return }
        self.connectionState = .failed("无法打开 T3 线程；请检查 Server 和 Pi Provider 模型。")
        self.isLoadingConfiguration = false
        self.statusText =
          self.isShowingCachedConversation
          ? "暂时无法核对会话，当前显示本地缓存；连接恢复后会同步。"
          : "命令结果未确认时不会自动重试，请刷新列表后检查。"
        completion?(false)
      }
    }
  }

  private func observeThread(_ id: String, on server: T3DesktopClient) {
    currentSessionPath = "t3:\(id)"
    if let projectURL {
      skillWorkspaceContext = WorkspaceSkillContext(
        instanceID: "pi", projectCwd: projectURL.path, threadID: id)
      enterSkillWorkspace()
    }
    server.watch(
      id, owner: observerID, visible: needsConversationUpdates,
      receiveUI: { [weak self] snapshot in self?.applyExtensionUI(snapshot) },
      receive: { [weak self] detail in self?.apply(detail) })
  }

  func newSession(completion: ((Bool) -> Void)? = nil) {
    guard !isBusy, let projectURL else {
      completion?(false)
      return
    }
    messages = []
    open(project: projectURL, path: nil, completion: completion)
  }
  func switchSession(path: String, in projectURL: URL, completion: ((Bool) -> Void)? = nil) {
    guard !isBusy else {
      completion?(false)
      return
    }
    open(project: projectURL, path: path, completion: completion)
  }
  func resumeProcess(sessionPath: String?, continueLastSession: Bool) {
    guard let projectURL else { return }
    open(
      project: projectURL,
      path: sessionPath ?? (currentSessionPath.isEmpty ? nil : currentSessionPath))
  }
  // UI selection never suspends a Provider runtime.
  func suspendProcess() {}
  func disconnect() {
    closeAccountWorkspace()
    browserPreview.stop()
    extensionUI?.removeRequests(from: self)
    isManagingSessionAccounts = false
    serverQueuedPrompts.removeAll()
    goalState = .none
    generation = UUID()
    connectTask?.cancel()
    connectTask = nil
    server?.unwatch(owner: observerID)
    server?.leaveSkillWorkspace(owner: observerID)
    skillWorkspaceContext = nil
    connectionState = .disconnected
    // Detaching a view must not stop a T3 task running for iOS/Telegram.
  }
  func discardEmptyDraft() {
    guard !hasUserMessage, !isBusy, let id = threadID, let server else {
      disconnect()
      return
    }
    Task { try? await server.dispatch(["type": "thread.delete", "threadId": id]) }
    disconnect()
  }

  private var modelSelection: [String: Any] {
    [
      "instanceId": "pi", "model": selectedModelId,
      "options": [["id": "thinking", "value": selectedThinkingLevel]]
        + (fastModeAvailable ? [["id": "fastMode", "value": fastModeEnabled ? "on" : "off"]] : []),
    ]
  }
  func sendPrompt(delivery: QueuedPromptDelivery = .steer) {
    if let reason = promptSubmissionUnavailableReason {
      statusText = reason
      return
    }
    guard let prompt = Self.makePrompt(composerText, attachments: attachments, delivery: delivery)
    else { return }
    submit(prompt, clearComposer: true) { _ in }
  }
  /// 新目标不要求已有 Goal 快照；复用扩展原有入口，保持 composer 草稿完全独立。
  @discardableResult
  func startGoal(objective: String, mode: GoalStartMode) -> Bool {
    guard goalCreationUnavailableReason == nil,
      let command = mode.command(objective: objective),
      let prompt = Self.makePrompt(command, attachments: [], delivery: .followUp)
    else { return false }
    submit(prompt) { _ in }
    return true
  }

  /// 原生命令独立提交，不读取或清空正在编辑的正文和附件，也不在忙碌时排队控制命令。
  func sendGoalCommand(_ command: String) {
    guard canSubmitPrompt, !isBusy,
      case .available(_, driver: "pi") = goalState,
      let prompt = Self.makePrompt(command, attachments: [], delivery: .followUp)
    else { return }
    submit(prompt) { _ in }
  }

  func sendRemotePrompt(
    _ text: String, attachments: [PromptAttachment] = [], messageID: String? = nil,
    completion: @escaping (Bool) -> Void
  ) {
    guard canSubmitPrompt, !isBusy,
      let prompt = Self.makePrompt(text, attachments: attachments, delivery: .followUp)
    else {
      completion(false)
      return
    }
    submit(prompt, messageID: messageID, completion: completion)
  }
  private func submit(
    _ prompt: QueuedPrompt, messageID: String? = nil, clearComposer: Bool = false,
    completion: @escaping (Bool) -> Void
  ) {
    guard let server, let projectURL, let deliveryCoordinator, !submitting else {
      completion(false)
      return
    }
    let id = messageID ?? UUID().uuidString
    let target = threadID ?? UUID().uuidString
    do {
      _ = try deliveryCoordinator.store.save(
        prompt: prompt, messageID: id, threadID: target, project: projectURL,
        selection: modelSelection, createsThread: threadID == nil, context: recoveryContext,
        replacingDraftID: clearComposer
          ? deliveryRecords.first(where: { $0.state == .draft })?.id : nil)
    } catch {
      statusText = deliveryCoordinator.store.failure ?? "输入保存失败，尚未发送；草稿已保留"
      completion(false)
      return
    }
    // 持久化交接完成后才清理本次输入，异步结果不会清空后来编辑的草稿。
    if clearComposer {
      composerText = ""
      let ids = Set(prompt.attachments.map(\.id))
      attachments.removeAll { ids.contains($0.id) }
    }
    observeThread(target, on: server)
    performDelivery(id, completion: completion)
    refreshDeliveryPresentation()
  }

  private func performDelivery(_ id: String, completion: @escaping (Bool) -> Void) {
    guard let deliveryCoordinator else {
      completion(false)
      return
    }
    submitting = true
    recoveryChecked = false
    awaitingAgentStart = false
    submittedFromTurnID = lastTurnID
    let current = generation
    submissionTask = Task { [weak self] in
      let success = await deliveryCoordinator.deliver(
        id, retryDelays: [.seconds(1), .seconds(3), .seconds(8)])
      completion(success)
      guard let self, self.generation == current else { return }
      self.submitting = false
      self.submissionTask = nil
      self.statusText = deliveryCoordinator.store.message(id)?.issue ?? ""
      self.refreshDeliveryPresentation()
      self.server?.requestRefresh()
    }
  }

  var deliveryRecords: [OutboxMessage] {
    guard let threadID, let projectURL else { return [] }
    return deliveryCoordinator?.store.records(threadID: threadID, project: projectURL) ?? []
  }
  var recoveryRecords: [OutboxMessage] {
    deliveryRecords.filter {
      ($0.state.needsRecovery && !($0.state == .saved && submitting))
        || ($0.state == .accepted && connectionState != .connected)
    }.sorted { ($0.state == .draft ? 1 : 0) < ($1.state == .draft ? 1 : 0) }
  }
  var deliveryStorageFailure: String? { deliveryCoordinator?.store.failure }
  @Published private(set) var isCheckingDelivery = false
  @Published private(set) var recoveryReady = false
  @Published private(set) var recoveryChecked = false
  private var deliveryObservation: AnyCancellable?
  private var displayedOutboxIDs: Set<String> = []
  private var restoredDeliveryDrafts: Set<String> = []

  private var recoveryContext: String {
    let ids = Set(deliveryRecords.map(\.id))
    return messages.filter {
      [.user, .assistant, .compaction].contains($0.kind) && !ids.contains($0.id)
    }.map { "\($0.kind == .user ? "用户" : "助手")：\($0.text)" }.joined(separator: "\n\n")
  }

  private func refreshDeliveryPresentation() {
    if let draft = deliveryRecords.first(where: { $0.state == .draft }),
      restoredDeliveryDrafts.insert(draft.id).inserted, !hasUnsubmittedInput
    {
      composerText = draft.text
      attachments = draft.attachments.map(\.attachment)
    }
    let pending = pendingSentMessages
    messages.removeAll { displayedOutboxIDs.contains($0.id) }
    let visibleIDs = Set(messages.map(\.id))
    messages.append(contentsOf: pending.filter { !visibleIDs.contains($0.id) })
    messages.sort { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    displayedOutboxIDs = Set(pending.map(\.id))
    deliveryUpdates.send()
    objectWillChange.send()
  }

  // 只读核对与 Agent 执行互不排斥；同一线程的投递/核对仍由协调器串行化。
  var canCheckDeliveryRecovery: Bool {
    !isCheckingDelivery && !submitting && !recoveryRecords.isEmpty
      && !(threadID.map { deliveryCoordinator?.activeThreads.contains($0) == true } ?? false)
  }

  var canContinueDeliveryRecovery: Bool {
    canCheckDeliveryRecovery && recoveryReady && !isCompacting && pendingSelection == nil
      && !codexRotationInFlight && !isChangingFastMode && !isManagingAccounts
      && extensionUI?.hasPendingDialog(for: self) != true
  }

  func checkDeliveryRecovery() {
    guard canCheckDeliveryRecovery, let deliveryCoordinator else { return }
    isCheckingDelivery = true
    recoveryReady = false
    recoveryChecked = false
    let ids = recoveryRecords.map(\.id)
    let current = generation
    Task { [weak self] in
      var ready = false
      var reachable = false
      for id in ids {
        let result = await deliveryCoordinator.check(id)
        if result == .ready { ready = true }
        if [.ready, .accepted, .needsEditing].contains(result) { reachable = true }
      }
      guard let self, self.generation == current else { return }
      self.isCheckingDelivery = false
      self.recoveryChecked = true
      self.recoveryReady = ready && !self.recoveryRecords.contains { $0.state == .missing }
      if reachable, let server = self.server, let threadID = self.threadID {
        self.observeThread(threadID, on: server)
        self.connectionState = .connected
      }
      self.refreshDeliveryPresentation()
      self.server?.requestRefresh()
    }
  }

  func continueDeliveryRecovery() {
    guard canContinueDeliveryRecovery, let first = recoveryRecords.first, let server else { return }
    recoveryReady = false
    observeThread(first.threadID, on: server)
    connectionState = .connected
    isLoadingConfiguration = false
    performDelivery(first.id) { _ in }
  }

  var migrationPreview: String {
    MessageOutboxStore.migrationText(
      recoveryRecords,
      context: recoveryRecords.max { $0.context.count < $1.context.count }?.context ?? "")
  }

  func migrateDeliveryRecovery() {
    guard !submitting, !isCheckingDelivery, !isBusy, let deliveryCoordinator, let server else {
      return
    }
    do {
      let target = try deliveryCoordinator.store.migrate(recoveryRecords)
      // 目标与来源映射已原子保存，退出后仍从同一迁移目标继续。
      observeThread(target.threadID, on: server)
      messages = []
      displayedOutboxIDs = []
      connectionState = .connected
      recoveryReady = false
      refreshDeliveryPresentation()
      performDelivery(target.id) { _ in }
    } catch { statusText = MessageRecoveryCoordinator.issue(error) }
  }

  func retryDeliveryStorage() {
    guard !isBusy, let store = deliveryCoordinator?.store else { return }
    do {
      try store.retryPersistence()
      statusText = store.failure ?? "本地保存已恢复；可继续发送或检查待恢复输入"
      refreshDeliveryPresentation()
    } catch { statusText = store.failure ?? "本地保存仍不可用，原稿已保留" }
  }

  func stopDeliveryRecovery() {
    guard !isBusy, let first = recoveryRecords.first, let store = deliveryCoordinator?.store else {
      return
    }
    do {
      try store.update(first.id) { $0.state = .dismissed }
      statusText = "已停止本地恢复，记录和附件仍保留；没有取消 Server 任务"
      refreshDeliveryPresentation()
    } catch { statusText = MessageRecoveryCoordinator.issue(error) }
  }

  func exportDeliveryRecovery() {
    guard let store = deliveryCoordinator?.store, !recoveryRecords.isEmpty else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "导出到此处"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      let folder = try store.export(recoveryRecords, to: destination)
      NSWorkspace.shared.activateFileViewerSelecting([folder])
      statusText = "原稿与保留附件已导出；没有重发或取消旧请求"
    } catch { statusText = "导出失败，请检查目标目录权限；本机原记录仍保留" }
  }

  var canTakeBackDeliveryDraft: Bool {
    !isBusy && !hasUnsubmittedInput && connectionState == .connected
      && recoveryRecords.first.map { $0.state != .missing } == true
  }

  func takeBackDeliveryDraft() {
    guard canTakeBackDeliveryDraft,
      let first = recoveryRecords.first, let store = deliveryCoordinator?.store
    else { return }
    do {
      try store.update(first.id) {
        $0.state = .draft
        $0.issue = "原稿已取回并保留备份；重新发送前请核验旧请求是否已执行"
      }
      composerText = first.text
      attachments = first.attachments.map(\.attachment)
      statusText = "原稿已取回；这不会撤销旧请求，重新发送前请核验是否已执行"
      recoveryReady = false
      refreshDeliveryPresentation()
    } catch { statusText = MessageRecoveryCoordinator.issue(error) }
  }

  var showsStopControl: Bool {
    threadID != nil
      && (isStreaming || isCompacting || submitting || awaitingAgentStart || isStopping
        || threadID.flatMap { server?.thread($0)?["status"] as? String } == "running")
  }

  func abort() {
    guard let id = threadID, let server, server.isConnected, !isStopping else { return }
    let current = generation
    // 停止本次本地准备/退避，禁止它在停止命令之后继续派发；已发出的结果仍按未知保留。
    // 不等待上传、转录核对或投递回执，控制命令使用共享 RPC 的独立请求。
    submissionTask?.cancel()
    isStopping = true
    statusText = "正在停止任务并暂停队列…"
    Task {
      do {
        try await server.interrupt(threadID: id)
        guard generation == current else { return }
        isStopping = false
        awaitingAgentStart = false
        statusText = "停止请求已确认，正在同步任务状态；已执行的操作不会撤销。"
      } catch {
        guard generation == current else { return }
        isStopping = false
        statusText = "停止未确认，请检查 Server 状态；不会自动重发。"
        server.requestRefresh()
      }
    }
  }
  func changeModel(to id: String) {
    guard !isBusy, models.contains(where: { $0.id == id }) else { return }
    selectedModelId = id
    fastModeAvailable = fastModeSupported(id)
    if !fastModeAvailable { fastModeEnabled = false }
    if modelPreferenceKey != "defaultNewSessionModelID" {
      UserDefaults.standard.set(id, forKey: modelPreferenceKey)
    }
    thinkingLevels = models.first { $0.id == id }?.thinkingLevels ?? ["off"]
    if !thinkingLevels.contains(selectedThinkingLevel) { selectedThinkingLevel = "off" }
    persistSelection()
  }
  func selectRemoteModel(_ id: String) async -> Bool {
    changeModel(to: id)
    return selectedModelId == id
  }
  func changeThinkingLevel(to level: String) {
    guard !isBusy, thinkingLevels.contains(level) else { return }
    selectedThinkingLevel = level
    persistSelection()
  }
  private func persistSelection() {
    guard let id = threadID, let server else { return }
    let selection = modelSelection
    let current = generation
    pendingSelection = selection
    Task {
      do {
        try await server.dispatch([
          "type": "thread.model-selection.set", "threadId": id, "modelSelection": selection,
        ])
      } catch {
        guard generation == current else { return }
        pendingSelection = nil
        if let selection = server.thread(id)?["modelSelection"] as? [String: Any] {
          fastModeEnabled =
            (selection["options"] as? [[String: Any]])?.first {
              $0["id"] as? String == "fastMode"
            }?["value"] as? String == "on"
        }
        statusText = "模型/推理级别/Fast 变更未确认，请刷新 Server 状态。"
        server.requestRefresh()
      }
    }
  }

  func refreshModels() {
    guard let provider = server?.providers.first(where: { $0["instanceId"] as? String == "pi" })
    else { return }
    allModels = (provider["models"] as? [[String: Any]] ?? []).compactMap { model in
      guard let slug = model["slug"] as? String, let slash = slug.firstIndex(of: "/") else {
        return nil
      }
      let capabilities = model["capabilities"] as? [String: Any]
      let descriptor = (capabilities?["optionDescriptors"] as? [[String: Any]])?.first {
        $0["id"] as? String == "thinking"
      }
      let levels =
        (descriptor?["options"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? ["off"]
      return PiModel(
        provider: String(slug[..<slash]), modelId: String(slug[slug.index(after: slash)...]),
        name: model["name"] as? String ?? slug,
        reasoning: levels.count > 1, thinkingLevels: levels,
        defaultContextWindow: server?.modelContextSettings.defaults[slug])
    }
    let hidden = server?.hiddenModelIDs ?? []
    models = allModels.filter { !hidden.contains($0.id) }
    let selectingDefault = selectedModelId.isEmpty
    if selectingDefault {
      selectedModelId =
        defaultModelID.flatMap { preference in models.first { $0.id == preference }?.id } ?? models
        .first?.id ?? ""
    }
    fastModeAvailable = fastModeSupported(selectedModelId)
    thinkingLevels = allModels.first { $0.id == selectedModelId }?.thinkingLevels ?? ["off"]
    if selectingDefault {
      selectedThinkingLevel =
        modelDefaultThinkingLevels[selectedModelId] ?? globalDefaultThinkingLevel
    }
    if !thinkingLevels.contains(selectedThinkingLevel) { selectedThinkingLevel = "off" }
  }
  private func fastModeSupported(_ modelID: String) -> Bool {
    let provider = server?.providers.first { $0["instanceId"] as? String == "pi" }
    let model = (provider?["models"] as? [[String: Any]])?.first {
      $0["slug"] as? String == modelID
    }
    let capabilities = model?["capabilities"] as? [String: Any]
    return (capabilities?["optionDescriptors"] as? [[String: Any]])?.contains {
      $0["id"] as? String == "fastMode"
    } == true
  }
  func updateCatalog(_ values: [SessionItem]) {
    if sessions != values { sessions = values }
  }
  private func applyRunState(_ thread: [String: Any]) {
    let turn = thread["latestTurn"] as? [String: Any]
    let state = turn?["state"] as? String
    let turnID = turn?["turnId"] as? String
    let wasRunning = isStreaming
    let sessionFailed = (thread["session"] as? [String: Any])?["status"] as? String == "error"
    terminalStopReason =
      state == "interrupted" ? "aborted" : (state == "error" || sessionFailed) ? "error" : nil
    isStreaming =
      state == "running"
      || ["starting", "running"].contains(
        (thread["session"] as? [String: Any])?["status"] as? String ?? "")
    if isStreaming || (turnID != submittedFromTurnID && turnID != nil) || sessionFailed {
      awaitingAgentStart = false
    }
    if turnID != lastTurnID, isStreaming {
      speed.reset()
      outputTokensPerSecond = nil
      onTelegramLifecycleEvent?("agent_start")
    }
    if wasRunning, !isStreaming { onTelegramLifecycleEvent?("agent_end") }
    if lastTurnState != state, !isStreaming, turnID != nil {
      statusText = state == "error" ? "Pi 执行失败（Server 已记录）" : state == "interrupted" ? "任务已取消" : ""
    }
    lastTurnID = turnID
    lastTurnState = state
  }

  func apply(_ detail: [String: Any]) {
    guard let thread = detail["thread"] as? [String: Any], thread["id"] as? String == threadID
    else { return }
    connectionState = .connected
    if isShowingCachedConversation {
      isShowingCachedConversation = false
      if statusText == "正在后台核对会话…" { statusText = "" }
    }
    sessionName = thread["title"] as? String ?? ""
    goalState = ThreadGoal.State.read(thread["goal"], driver: thread["goalDriver"] as? String)
    queueHeld = thread["queueHeld"] as? Bool ?? false
    serverQueuedPrompts = (thread["queuedMessages"] as? [[String: Any]] ?? []).compactMap {
      guard let id = $0["runId"] as? String else { return nil }
      return ServerQueuedPrompt(
        id: id, text: $0["text"] as? String ?? "",
        attachments: $0["localImages"] as? [PromptAttachment] ?? [])
    }
    if let selection = thread["modelSelection"] as? [String: Any],
      pendingSelection == nil || NSDictionary(dictionary: pendingSelection!).isEqual(to: selection)
    {
      pendingSelection = nil
      fastModeEnabled =
        (selection["options"] as? [[String: Any]])?.first { $0["id"] as? String == "fastMode" }?[
          "value"] as? String == "on"
      selectedModelId = selection["model"] as? String ?? selectedModelId
      fastModeAvailable = fastModeSupported(selectedModelId)
      thinkingLevels = allModels.first { $0.id == selectedModelId }?.thinkingLevels ?? ["off"]
      if let options = selection["options"] as? [[String: Any]],
        let thinking = options.first(where: { $0["id"] as? String == "thinking" })?["value"]
          as? String
      {
        selectedThinkingLevel = thinking
      }
    }
    applyRunState(thread)
    let turnID = lastTurnID
    let state = lastTurnState
    // Metrics arrive with the thread snapshot, independently of account/quota
    // extensions (which can be unavailable or fail).
    if let metrics = detail["sessionStats"] as? [String: Any],
      let data = try? JSONSerialization.data(withJSONObject: metrics),
      let stats = try? JSONDecoder().decode(SessionStats.self, from: data)
    {
      self.stats = stats
      outputTokensPerSecond = stats.outputTokensPerSecond
    }
    refreshCodexAccounts()
    var entries = (thread["messages"] as? [[String: Any]] ?? []).map { message -> ChatEntry in
      let role = message["role"] as? String ?? "assistant"
      return ChatEntry(
        id: (role == "user" ? message["messageId"] as? String : nil)
          ?? message["id"] as? String ?? "",
        kind: role == "user"
          ? .user
          : role == "reasoning" ? .thinking : role == "compaction" ? .compaction : .assistant,
        title: role == "compaction"
          ? (message["title"] as? String ?? "上下文已压缩")
          : role == "user" ? "你" : role == "reasoning" ? "思考过程" : "Pi",
        text: message["text"] as? String ?? "",
        isRunning: message["streaming"] as? Bool ?? false,
        attachments: message["localImages"] as? [PromptAttachment] ?? [],
        htmlRender: message["htmlRender"] as? T3HTMLRender,
        htmlDocument: message["htmlDocument"] as? String,
        htmlRenderError: message["htmlRenderError"] as? String,
        timestamp: T3DesktopClient.date(message["createdAt"]),
        runID: message["runId"] as? String)
    }
    var toolEntries: [String: ChatEntry] = [:]
    var completedTools: Set<String> = []
    for activity in thread["activities"] as? [[String: Any]] ?? [] {
      let payload = activity["payload"] as? [String: Any] ?? [:]
      let kind = activity["kind"] as? String ?? ""
      guard kind.hasPrefix("tool.") || kind.contains("error") || kind.contains("warning") else {
        continue
      }
      let data = payload["data"] as? [String: Any] ?? [:]
      let rawOutput = data["rawOutput"] as? [String: Any]
      let output = rawOutput.map { Self.contentText($0["content"]) }
      let toolCallID = payload["toolCallId"] as? String ?? activity["id"] as? String ?? ""
      let entryID =
        kind.hasPrefix("tool.")
        ? "\(activity["turnId"] as? String ?? ""):\(toolCallID)" : toolCallID
      var entry = ChatEntry(
        id: entryID,
        kind: kind.hasPrefix("tool.") ? .tool : .system,
        title: activity["summary"] as? String ?? kind,
        text: output ?? payload["detail"] as? String ?? payload["message"] as? String ?? "",
        isRunning: payload["status"] as? String == "inProgress",
        isError: payload["status"] as? String == "failed" || kind.contains("error"),
        toolName: data["toolName"] as? String ?? payload["title"] as? String,
        toolInput: Self.toolInputText(
          toolName: data["toolName"] as? String ?? payload["title"] as? String ?? "",
          args: data["input"]
        ) ?? (data["command"] as? String).map { "$ \($0)" },
        parentToolEntryID: (data["parentToolCallId"] as? String).map {
          "\(activity["turnId"] as? String ?? ""):\($0)"
        },
        nestedCalls: NestedToolCall.from(data["nestedCalls"]),
        nestedCallsComplete: (data["nestedCalls"] as? [String: Any])?["complete"] as? Bool ?? true,
        diff: data["diff"] as? String,
        attachments: data["localImages"] as? [PromptAttachment] ?? [],
        timestamp: T3DesktopClient.date(activity["createdAt"]),
        runID: activity["turnId"] as? String)
      if kind.hasPrefix("tool.") {
        entry.toolInput = entry.toolInput ?? toolEntries[entryID]?.toolInput
        entry.parentToolEntryID = entry.parentToolEntryID ?? toolEntries[entryID]?.parentToolEntryID
        if completedTools.contains(entryID), let input = entry.toolInput {
          toolEntries[entryID]?.toolInput = input
          toolEntries[entryID]?.parentToolEntryID = entry.parentToolEntryID
        }
        // Native activities are not guaranteed to be ordered when timestamps
        // tie. Terminal output must beat stale started/updated records.
        if kind == "tool.completed" || kind == "tool.failed" {
          toolEntries[entryID] = entry
          completedTools.insert(entryID)
        } else if !completedTools.contains(entryID) {
          toolEntries[entryID] = entry
        }
      } else {
        entries.append(entry)
      }
    }
    // 用消息身份去重而非文本：相同内容连续发送仍是不同消息。
    // 排队消息确认后由队列 UI 展示，避免取消队列后留下虚假的聊天记录。
    let confirmedIDs = Set(entries.map(\.id)).union(
      (thread["queuedMessages"] as? [[String: Any]] ?? []).compactMap {
        $0["messageId"] as? String ?? $0["id"] as? String
      })
    do {
      if let threadID {
        try deliveryCoordinator?.store.acknowledge(threadID: threadID, messageIDs: confirmedIDs)
      }
    } catch { statusText = "消息已收到，但本地交接保存失败；请检查发件箱" }
    entries.append(contentsOf: ChatEntry.groupingToolEntries(Array(toolEntries.values)))
    entries.sort { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    if let projectURL, let threadID {
      server?.conversationCache.store(
        project: projectURL, threadID: threadID, title: sessionName, messages: entries)
    }
    entries.append(contentsOf: pendingSentMessages.filter { !confirmedIDs.contains($0.id) })
    displayedOutboxIDs = Set(pendingSentMessages.map(\.id))
    entries.sort { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    if messages != entries { messages = entries }
    if !isStreaming, let turnID, state != nil, lastSettledTurnID != turnID {
      lastSettledTurnID = turnID
    }
  }

  func refreshSessionMetadata() { server?.requestRefresh() }
  func refreshExternalTranscript(at path: String) { server?.requestRefresh() }
  func applyRemoteSessionSnapshot(from source: AppModel) { server?.requestRefresh() }
  func reloadModelList() {
    guard canReloadModelList, !isLoadingConfiguration, let server else { return }
    isLoadingConfiguration = true
    Task {
      defer { isLoadingConfiguration = false }
      do {
        try await server.loadConfig()
        refreshModels()
      } catch {
        statusText = "模型配置刷新失败：\(error.localizedDescription)"
      }
    }
  }

  func setModelContextWindow(_ tokens: Int?, for modelID: String) async throws {
    guard let server, server.isConnected, !isLoadingConfiguration else {
      throw T3DesktopClient.ClientError.unavailable
    }
    try ModelContextLimit.validate(tokens)
    isLoadingConfiguration = true
    defer { isLoadingConfiguration = false }
    // Server 写入 Pi 的模型元数据，不改会话统计，也不打断任何正在执行的线程。
    try await server.setModelContextWindow(tokens, modelID: modelID)
    refreshModels()
    showTransientStatus("上下文限制已保存；新的 Pi 进程生效，已有会话不会立即变更。")
  }

  func refreshModelPreferences() { refreshModels() }
  func setModelVisible(_ visible: Bool, modelID: String) {
    guard let server, server.isConnected, !isLoadingConfiguration else { return }
    isLoadingConfiguration = true
    Task {
      defer { isLoadingConfiguration = false }
      do {
        try await server.setModelVisible(visible, modelID: modelID)
        refreshModels()
      } catch {
        statusText = "模型显示设置未确认，请刷新 Server 状态：\(error.localizedDescription)"
      }
    }
  }
  func setDefaultModel(_ modelID: String?) {
    defaultModelID = modelID
    UserDefaults.standard.set(modelID, forKey: "defaultNewSessionModelID")
  }
  func setGlobalDefaultThinkingLevel(_ level: String) {
    globalDefaultThinkingLevel = level
    UserDefaults.standard.set(level, forKey: "t3DefaultThinkingLevel")
  }
  func setDefaultThinkingLevel(_ level: String?, for modelID: String) {
    modelDefaultThinkingLevels[modelID] = level
    UserDefaults.standard.set(modelDefaultThinkingLevels, forKey: "t3ModelDefaultThinkingLevels")
  }
  func compact() {
    guard canRestartSafely, isProcessRunning else { return }
    performSessionControl("compact")
  }
  private func performSessionControl(_ operation: String, accountName: String? = nil) {
    guard let id = threadID, let server else { return }
    let current = generation
    awaitingAgentStart = true
    submittedFromTurnID = lastTurnID
    if operation == "compact" {
      isCompacting = true
    } else {
      codexRotationInFlight = true
    }
    statusText = operation == "compact" ? "正在压缩上下文…" : "正在切换账户…"
    Task { [weak self] in
      guard let self else { return }
      defer {
        if self.generation == current {
          self.isCompacting = false
          self.codexRotationInFlight = false
          self.refreshCodexAccounts()
        }
      }
      do {
        try await server.sessionControl(
          threadID: id, operation: operation, accountName: accountName)
        guard self.generation == current else { return }
        self.statusText =
          operation == "compact"
          ? "压缩请求已提交；等待 Server 完成。" : "切换请求已提交：\(accountName ?? "")；请以 Pi 的执行结果为准。"
      } catch {
        guard self.generation == current else { return }
        self.awaitingAgentStart = false
        self.statusText = "操作未确认；请检查会话状态和扩展配置，不会自动重试。"
      }
    }
  }
  func switchCodexAccount(to accountName: String) {
    guard canRestartSafely, supportsAccountSwitch,
      T3DesktopClient.isSwitchableAccountName(accountName),
      extensionUI?.usage(for: self).accounts.contains(where: {
        $0.name == accountName && !$0.isActive
      }) == true
    else { return }
    performSessionControl("switch-account", accountName: accountName)
  }
  func refreshCodexAccounts(force: Bool = false) {
    guard accountStatusTask == nil, let server else { return }
    guard let provider = accountUsageProvider else {
      if !accountQuotaMessage.isEmpty { accountQuotaMessage = "" }
      return
    }
    let refreshQuota = accountQuotaRefreshPolicy.shouldRefresh(
      generation: generation, provider: provider, isActive: isBusy, force: force)
    // 账户轮换不应等待 60/180 秒的额度查询周期；轻量读取不访问额度服务。
    if !refreshQuota, let lastPoll = accountSelectionLastPoll,
      ContinuousClock.now - lastPoll < .seconds(2)
    {
      return
    }
    accountSelectionLastPoll = .now
    let threadID = self.threadID ?? "@discovery"
    let current = generation
    isRefreshingAccountQuota = refreshQuota
    accountStatusTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.accountStatusTask = nil
        self.isRefreshingAccountQuota = false
      }
      do {
        // Host quotas are independent of official per-thread token metrics.
        if let payload = try await server.accountStatus(
          threadID: threadID, provider: provider.rawValue, force: force,
          selectionOnly: !refreshQuota),
          self.generation == current, self.accountUsageProvider == provider
        {
          if refreshQuota { self.accountQuotaMessage = "" }
          let data = try JSONSerialization.data(withJSONObject: payload)
          self.extensionUI?.handle(
            [
              "method": "setStatus", "id": "server-account-status",
              "statusKey": "account-usage-gui", "statusText": String(decoding: data, as: UTF8.self),
            ], from: self)
        } else if refreshQuota, self.generation == current, self.accountUsageProvider == provider {
          self.accountQuotaMessage = ""
        }
      } catch {
        if refreshQuota, self.generation == current, self.accountUsageProvider == provider {
          self.accountQuotaMessage = "账户额度查询失败；已有数据仅为旧缓存。请检查授权、文件权限及本机 Server。"
        }
      }
    }
  }
  func openCodexAccountManager() {
    guard canManageAccounts, let provider = accountUsageProvider, let server else { return }
    accountWorkspace = AccountWorkspaceModel(
      provider: provider, snapshot: nil,
      transport: { input in try await server.accountControl(input) },
      openURL: { NSWorkspace.shared.open($0) })
  }

  func closeAccountWorkspace() {
    guard let accountWorkspace else { return }
    accountWorkspace.close()
    self.accountWorkspace = nil
    refreshCodexAccounts(force: true)
  }

  func applyExtensionUI(_ snapshot: [String: Any]) {
    let epoch = snapshot["epoch"] as? String ?? ""
    if extensionUIEpoch != epoch {
      extensionUIEpoch = epoch
      extensionUISerial = 0
      answeredDialogIDs.removeAll()
    }
    let busy = snapshot["busy"] as? Bool ?? false
    if isManagingSessionAccounts != busy { isManagingSessionAccounts = busy }
    let requests = snapshot["requests"] as? [[String: Any]] ?? []
    let ids = Set(requests.compactMap { $0["id"] as? String })
    answeredDialogIDs.formIntersection(ids)
    extensionUI?.reconcileRequests(ids: ids.subtracting(answeredDialogIDs), from: self)
    for event in snapshot["events"] as? [[String: Any]] ?? [] {
      guard let serial = event["serial"] as? Int, serial > extensionUISerial else { continue }
      extensionUISerial = serial
      extensionUI?.handle(event, from: self)
    }
    for request in requests {
      guard let id = request["id"] as? String, !answeredDialogIDs.contains(id) else { continue }
      extensionUI?.handle(request, from: self)
    }
  }
  func changeFastMode(to enabled: Bool) {
    guard canRestartSafely, fastModeAvailable else { return }
    fastModeEnabled = enabled
    persistSelection()
  }
  func sendExtensionResponse(
    id: String, value: String? = nil, confirmed: Bool? = nil, cancelled: Bool = false
  ) {
    guard let threadID, let server else { return }
    let current = generation
    answeredDialogIDs.insert(id)
    Task {
      do {
        try await server.extensionResponse(
          threadID: threadID, id: id, value: value, confirmed: confirmed, cancelled: cancelled)
      } catch {
        guard generation == current else { return }
        statusText = "扩展回复未确认或已过期；不会自动重发，请检查会话状态。"
      }
    }
  }
  func appendExtensionNotification(_ text: String) { statusText = text }
  private func unsupported(_ name: String) {
    statusText = "\(name)尚未接入 Pi Provider Adapter；不会回退到桌面 RPC。"
  }
  private func queueCommand(_ fields: [String: Any]) {
    guard let id = threadID, let server else { return }
    Task {
      do {
        try await server.dispatch(fields.merging(["threadId": id]) { _, new in new })
      } catch {
        statusText = "队列操作未确认；请刷新 Server 状态，不会自动重发。"
      }
    }
  }
  func resumeQueue() { queueCommand(["type": "queue.resume"]) }
  func removeQueuedPrompt(id: String, restoreDraft: Bool = false) {
    guard let prompt = serverQueuedPrompts.first(where: { $0.id == id }),
      let threadID, let server, !pendingQueueCancellations.contains(id)
    else { return }
    guard !restoreDraft || !hasUnsubmittedInput else {
      statusText = "请先发送或清空输入框，避免覆盖尚未提交的草稿。"
      return
    }
    let current = generation
    pendingQueueCancellations.insert(id)
    statusText = "正在取消这条排队消息…"
    Task {
      do {
        try await server.dispatch([
          "type": "queued-run.cancel", "threadId": threadID, "runId": id,
        ])
        guard generation == current else { return }
        pendingQueueCancellations.remove(id)
        if restoreDraft, !hasUnsubmittedInput {
          composerText = prompt.text
          attachments = prompt.attachments
        }
        statusText = "Server 已取消这条排队消息。"
      } catch {
        guard generation == current else { return }
        pendingQueueCancellations.remove(id)
        statusText = "取消未确认；消息可能已经开始执行，请检查状态，必要时停止任务。"
      }
    }
  }
  func queuedPromptMoveTarget(id: String, direction: Int) -> String? {
    guard direction == -1 || direction == 1,
      let index = serverQueuedPrompts.firstIndex(where: { $0.id == id }),
      serverQueuedPrompts.indices.contains(index + direction)
    else { return nil }
    return serverQueuedPrompts[index + direction].id
  }
  func moveQueuedPrompt(id: String, direction: Int) {
    guard let target = queuedPromptMoveTarget(id: id, direction: direction),
      let to = serverQueuedPrompts.firstIndex(where: { $0.id == target })
    else { return }
    let before: Any =
      direction == -1
      ? target
      : (serverQueuedPrompts.indices.contains(to + 1)
        ? serverQueuedPrompts[to + 1].id as Any : NSNull())
    queueCommand(["type": "queued-run.reorder", "runId": id, "beforeRunId": before])
  }
  func editMessage(_ text: String) { composerText = text }
  func replyDocumentURL(for url: URL) async throws -> URL {
    guard let path = T3ReplyDocumentLinks.path(for: url), let id = threadID, let server else {
      throw T3DesktopClient.ClientError.rejected
    }
    let signed = try await server.replyDocumentURL(path: path, threadID: id)
    guard threadID == id else { throw CancellationError() }
    if let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .percentEncodedFragment
    {
      var components = URLComponents(url: signed, resolvingAgainstBaseURL: false)
      components?.percentEncodedFragment = fragment
      return components?.url ?? signed
    }
    return signed
  }

  func replyImage(for url: URL) async throws -> PromptAttachment {
    guard let path = T3ReplyImageLinks.path(for: url), let id = threadID, let server else {
      throw T3DesktopClient.ClientError.rejected
    }
    let image = try await server.replyImage(path: path, threadID: id)
    guard threadID == id else { throw CancellationError() }
    return image
  }

  func removeAttachment(_ attachment: PromptAttachment) {
    attachments.removeAll { $0.id == attachment.id }
  }
  @discardableResult func addAttachments(_ urls: [URL]) -> [PromptAttachment] {
    let existing = Set(attachments.map(\.url))
    let added = urls.filter { $0.isFileURL && !existing.contains($0) }.map {
      PromptAttachment(
        url: $0, mimeType: UTType(filenameExtension: $0.pathExtension)?.preferredMIMEType)
    }
    attachments.append(contentsOf: added)
    return added
  }
  func addPastedImage(_ data: Data, mimeType: String) -> [PromptAttachment] {
    let directory = URL.applicationSupportDirectory.appendingPathComponent("PiMac/Attachments")
    let url = directory.appendingPathComponent(
      "pi-clipboard-\(UUID().uuidString).\(UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "png")"
    )
    do {
      // 粘贴图片随草稿跨重启恢复，不能依赖系统可随时清理的临时目录。
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      return addAttachments([url])
    } catch {
      statusText = "无法保存粘贴图片"
      return []
    }
  }
  nonisolated static func threadID(from path: String) -> String? {
    guard path.hasPrefix("t3:"), path.count > 3 else { return nil }
    return String(path.dropFirst(3))
  }
  nonisolated static func makePrompt(
    _ text: String, attachments: [PromptAttachment], delivery: QueuedPromptDelivery
  ) -> QueuedPrompt? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty || !attachments.isEmpty else { return nil }
    let display = value.isEmpty ? "请查看附件。" : value
    return QueuedPrompt(
      id: UUID(), text: display, rpcText: rpcText(for: display, attachments: attachments),
      delivery: delivery, attachments: attachments)
  }
  nonisolated static func rpcText(for text: String, attachments: [PromptAttachment]) -> String {
    let paths = attachments.filter { !$0.isImage }.map(\.url.path)
    return paths.isEmpty
      ? text
      : text + "\n\n<pi-mac-attached-files>\n" + paths.joined(separator: "\n")
        + "\n</pi-mac-attached-files>"
  }
  nonisolated static func preferredNewSessionModelID(
    currentModelID: String, defaults: UserDefaults = .standard,
    preferenceKey: String = "defaultNewSessionModelID"
  ) -> String? {
    let candidate =
      defaults.string(forKey: preferenceKey)
      ?? (preferenceKey == "defaultNewSessionModelID" ? nil : currentModelID)
    guard let candidate, let slash = candidate.firstIndex(of: "/"), slash != candidate.startIndex,
      candidate.index(after: slash) != candidate.endIndex
    else { return nil }
    return candidate
  }
}

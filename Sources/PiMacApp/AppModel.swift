import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// Presentation state for one T3 thread. No Pi process, RPC transport or file writer.
@MainActor
final class AppModel: ObservableObject {
  @Published var connectionState: ConnectionState = .disconnected
  @Published var projectURL: URL?
  @Published var messages: [ChatEntry] = []
  var conversationTurns: [ConversationTurn] { ConversationTurn.group(messages) }
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
  @Published private(set) var isManagingAccounts = false
  private var startingAccountManagement = false
  private var extensionUIEpoch = ""
  private var extensionUISerial = 0
  private var answeredDialogIDs: Set<String> = []
  @Published private(set) var awaitingAgentStart = false
  @Published private(set) var lastSettledTurnID: String?
  private(set) var terminalStopReason: String?
  @Published var isStreaming = false
  @Published var isCompacting = false
  @Published var isLoadingConfiguration = false
  @Published var sessionName = ""
  @Published var sessions: [SessionItem] = []
  /// Compatibility name for UI/TG metadata; contains t3:<thread-id>, NEVER a file path.
  @Published var currentSessionPath = ""
  @Published var stats: SessionStats?
  @Published var composerText = ""
  @Published var attachments: [PromptAttachment] = []
  @Published var queuedPrompts: [QueuedPrompt] = []
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
  private let observerID = UUID()
  private var connectTask: Task<Void, Never>?
  private var generation = UUID()
  private var submitting = false
  private var pendingSelection: [String: Any]?
  private var submittedFromTurnID: String?
  private var lastTurnID: String?
  private var lastTurnState: String?
  private var pendingThreadPath: String?
  private var modelPreferenceKey = "defaultNewSessionModelID"
  private var speed = OutputSpeedTracker()
  private var accountStatusTask: Task<Void, Never>?
  private var accountQuotaRefreshPolicy = AccountQuotaRefreshPolicy()
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
    isStreaming || isCompacting || submitting || awaitingAgentStart || pendingSelection != nil
      || codexRotationInFlight || isChangingFastMode || isManagingAccounts
      || startingAccountManagement || extensionUI?.hasPendingDialog(for: self) == true
  }
  var canRestartSafely: Bool { !isBusy && !isLoadingConfiguration && queuedPrompts.isEmpty }
  var canReloadModelList: Bool { server?.isConnected == true && !isBusy }
  var canSubmitPrompt: Bool {
    server?.isConnected == true && connectionState == .connected && !isLoadingConfiguration
      && !isCompacting && !codexRotationInFlight && !submitting && !awaitingAgentStart
      && pendingSelection == nil
      && !isManagingAccounts && !startingAccountManagement
      && extensionUI?.hasPendingDialog(for: self) != true
  }
  var canReuseProcessForNewSession: Bool { false }  // A tab is a view, not a process pool slot.
  var hasUserMessage: Bool { messages.contains { $0.kind == .user } }
  var hasUnsubmittedInput: Bool {
    !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
  }
  var supportsFastMode: Bool { fastModeAvailable }
  @Published var accountQuotaMessage = ""
  @Published private(set) var isRefreshingAccountQuota = false
  var canManageAccounts: Bool {
    accountUsageProvider != nil && isProcessRunning && canRestartSafely && threadID != nil
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

  func attach(to server: T3DesktopClient) {
    self.server = server
    if let projectURL { open(project: projectURL, path: pendingThreadPath) }
  }
  func connect(to projectURL: URL, continueLastSession: Bool = true) {
    open(project: projectURL, path: nil)
  }
  private func open(project: URL, path: String?, completion: ((Bool) -> Void)? = nil) {
    extensionUI?.removeRequests(from: self)
    extensionUIEpoch = ""
    extensionUISerial = 0
    answeredDialogIDs.removeAll()
    isManagingAccounts = false
    queuedPrompts.removeAll()
    connectTask?.cancel()
    server?.unwatch(owner: observerID)
    generation = UUID()
    pendingSelection = nil
    stats = nil
    let current = generation
    projectURL = project.standardizedFileURL
    connectionState = .connecting
    isLoadingConfiguration = true
    statusText = "正在连接 T3 线程…"
    connectTask = Task { [weak self] in
      guard let self, let server = self.server else {
        completion?(false)
        return
      }
      do {
        try await server.waitUntilReady()
        try Task.checkCancellation()
        self.refreshModels()
        let projectID = try await server.ensureProject(project)
        let id: String
        if let path {
          guard let target = Self.threadID(from: path), let thread = server.thread(target),
            thread["projectId"] as? String == projectID
          else {
            throw T3DesktopClient.ClientError.rejected
          }
          id = target
        } else {
          guard !self.selectedModelId.isEmpty else { throw T3DesktopClient.ClientError.rejected }
          id = UUID().uuidString
          try await server.dispatch([
            "type": "thread.create", "threadId": id, "projectId": projectID,
            "title": "新任务", "modelSelection": self.modelSelection, "runtimeMode": "full-access",
            "interactionMode": "default", "branch": NSNull(), "worktreePath": NSNull(),
          ])
        }
        guard self.generation == current, !Task.isCancelled else { return }
        self.currentSessionPath = "t3:\(id)"
        self.pendingThreadPath = nil
        self.connectionState = .connected
        self.isLoadingConfiguration = false
        self.statusText = ""
        server.watch(
          id, owner: self.observerID,
          receiveUI: { [weak self] snapshot in
            self?.applyExtensionUI(snapshot)
          }
        ) { [weak self] detail in self?.apply(detail) }
        completion?(true)
      } catch {
        guard self.generation == current else { return }
        self.connectionState = .failed("无法打开 T3 线程；请检查 Server 和 Pi Provider 模型。")
        self.isLoadingConfiguration = false
        self.statusText = "命令结果未确认时不会自动重试，请刷新列表后检查。"
        completion?(false)
      }
    }
  }

  func newSession(completion: ((Bool) -> Void)? = nil) {
    guard !isBusy, let projectURL else {
      completion?(false)
      return
    }
    messages = []
    currentSessionPath = ""
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
    extensionUI?.removeRequests(from: self)
    isManagingAccounts = false
    queuedPrompts.removeAll()
    generation = UUID()
    connectTask?.cancel()
    connectTask = nil
    server?.unwatch(owner: observerID)
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
      "options": [["id": "thinking", "value": selectedThinkingLevel]],
    ]
  }
  func sendPrompt(delivery: QueuedPromptDelivery = .steer) {
    guard canSubmitPrompt,
      let prompt = Self.makePrompt(composerText, attachments: attachments, delivery: delivery)
    else { return }
    if isStreaming && delivery == .followUp {
      guard queuedPrompts.count < 100 else {
        statusText = "等待队列已满，请等待任务完成。"
        return
      }
      queuedPrompts.append(prompt)
      composerText = ""
      attachments = []
      statusText = "已排队，当前任务完成后发送。"
      return
    }
    submit(prompt) { [weak self] accepted in
      guard let self, accepted else { return }
      if self.composerText.trimmingCharacters(in: .whitespacesAndNewlines) == prompt.text {
        self.composerText = ""
      }
      let ids = Set(prompt.attachments.map(\.id))
      self.attachments.removeAll { ids.contains($0.id) }
    }
  }
  private func drainQueuedPrompts() {
    guard !isBusy, canSubmitPrompt, !queuedPrompts.isEmpty else { return }
    let prompt = queuedPrompts.removeFirst()
    submit(prompt) { [weak self] accepted in
      guard let self, !accepted else { return }
      self.statusText = "排队消息提交未确认，不会自动重发：\(prompt.text.prefix(120))"
      if self.composerText.isEmpty {
        self.composerText = prompt.text
        self.attachments = prompt.attachments
      }
    }
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
    _ prompt: QueuedPrompt, messageID: String? = nil, completion: @escaping (Bool) -> Void
  ) {
    guard let id = threadID, let server, !submitting else {
      completion(false)
      return
    }
    submitting = true
    let isSteering = isStreaming && prompt.delivery == .steer
    awaitingAgentStart = !isSteering
    submittedFromTurnID = lastTurnID
    let selection = modelSelection
    let submittedMessageID = messageID ?? UUID().uuidString
    Task { [weak self] in
      guard let self else { return }
      defer { self.submitting = false }
      do {
        let images: [[String: Any]] = try prompt.attachments.filter(\.isImage).map { attachment in
          let data = try Data(contentsOf: attachment.url)
          guard data.count <= 8 * 1024 * 1024, let mime = attachment.mimeType else {
            throw T3DesktopClient.ClientError.rejected
          }
          return [
            "type": "image", "name": attachment.url.lastPathComponent, "mimeType": mime,
            "sizeBytes": data.count, "dataUrl": "data:\(mime);base64,\(data.base64EncodedString())",
          ]
        }
        try await server.dispatch([
          "type": "message.dispatch", "threadId": id,
          "modelSelection": selection,
          "messageId": submittedMessageID, "text": prompt.rpcText,
          "attachments": try await server.persistAttachments(
            images, threadID: id, messageID: submittedMessageID),
          "dispatchMode": isSteering
            ? ["type": "steer_active", "targetRunId": try requireActiveRunID()]
            : ["type": "start_immediately"],
        ])
        completion(true)
        self.statusText = isSteering ? "已提交插入消息，当前工具调用结束后处理。" : "已提交到 T3 Server"
        // Server owns initial naming, including first messages sent from mobile.
      } catch {
        self.awaitingAgentStart = false
        completion(false)
        self.statusText = "提交未确认；请检查会话后再操作，不会自动重发。"
      }
    }
  }
  private func requireActiveRunID() throws -> String {
    guard let id = lastTurnID else { throw T3DesktopClient.ClientError.rejected }
    return id
  }
  func abort() {
    queuedPrompts.removeAll()
    guard let id = threadID, let server else { return }
    Task {
      do {
        if isCompacting {
          try await server.interrupt(threadID: id)
        } else {
          try await server.interrupt(threadID: id)
        }
      } catch {
        statusText = "取消未确认，请刷新状态。"
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
        reasoning: levels.count > 1, thinkingLevels: levels)
    }
    let hidden = Set(UserDefaults.standard.stringArray(forKey: "t3HiddenModels") ?? [])
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
  private func apply(_ detail: [String: Any]) {
    guard let thread = detail["thread"] as? [String: Any], thread["id"] as? String == threadID
    else { return }
    connectionState = .connected
    sessionName = thread["title"] as? String ?? ""
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
    if isStreaming || (turnID != submittedFromTurnID && turnID != nil)
      || (thread["session"] as? [String: Any])?["status"] as? String == "error"
    {
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
    lastTurnID = turnID
    lastTurnState = state
    var entries = (thread["messages"] as? [[String: Any]] ?? []).map { message -> ChatEntry in
      let role = message["role"] as? String ?? "assistant"
      return ChatEntry(
        id: message["id"] as? String ?? "",
        kind: role == "user" ? .user : role == "reasoning" ? .thinking : role == "compaction" ? .compaction : .assistant,
        title: role == "compaction" ? (message["title"] as? String ?? "上下文已压缩")
          : role == "user" ? "你" : role == "reasoning" ? "思考过程" : "Pi",
        text: message["text"] as? String ?? "",
        isRunning: message["streaming"] as? Bool ?? false,
        attachments: message["localImages"] as? [PromptAttachment] ?? [],
        timestamp: T3DesktopClient.date(message["createdAt"]))
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
        timestamp: T3DesktopClient.date(activity["createdAt"]))
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
    entries.append(contentsOf: ChatEntry.groupingToolEntries(Array(toolEntries.values)))
    entries.sort { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    if messages != entries { messages = entries }
    if !isStreaming, let turnID, state != nil, lastSettledTurnID != turnID {
      lastSettledTurnID = turnID
    }
    drainQueuedPrompts()
  }

  func refreshSessionMetadata() { server?.requestRefresh() }
  func refreshExternalTranscript(at path: String) { server?.requestRefresh() }
  func applyRemoteSessionSnapshot(from source: AppModel) { server?.requestRefresh() }
  func reloadModelList() {
    Task {
      try? await server?.loadConfig()
      refreshModels()
    }
  }
  func refreshModelPreferences() { refreshModels() }
  func setModelVisible(_ visible: Bool, modelID: String) {
    var hidden = Set(UserDefaults.standard.stringArray(forKey: "t3HiddenModels") ?? [])
    if visible { hidden.remove(modelID) } else { hidden.insert(modelID) }
    UserDefaults.standard.set(Array(hidden), forKey: "t3HiddenModels")
    refreshModels()
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
          self.drainQueuedPrompts()
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
    guard
      accountQuotaRefreshPolicy.shouldRefresh(
        generation: generation, provider: provider, isActive: isBusy, force: force
      )
    else { return }
    let threadID = self.threadID ?? "@discovery"
    let current = generation
    isRefreshingAccountQuota = true
    accountStatusTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.accountStatusTask = nil
        self.isRefreshingAccountQuota = false
      }
      do {
        // Host quotas are independent of official per-thread token metrics.
        if let payload = try await server.accountStatus(
          threadID: threadID, provider: provider.rawValue, force: force),
          self.generation == current, self.accountUsageProvider == provider
        {
          self.accountQuotaMessage = ""
          let data = try JSONSerialization.data(withJSONObject: payload)
          self.extensionUI?.handle(
            [
              "method": "setStatus", "id": "server-account-status",
              "statusKey": "account-usage-gui", "statusText": String(decoding: data, as: UTF8.self),
            ], from: self)
        } else if self.generation == current, self.accountUsageProvider == provider {
          self.accountQuotaMessage = ""
        }
      } catch {
        if self.generation == current, self.accountUsageProvider == provider {
          self.accountQuotaMessage = "账户额度查询失败；已有数据仅为旧缓存。请检查授权、文件权限及本机 Server。"
        }
      }
    }
  }
  func openCodexAccountManager() {
    guard canManageAccounts, let id = threadID, let server else { return }
    let current = generation
    startingAccountManagement = true
    statusText = "正在打开账户管理…"
    Task {
      defer { if generation == current { startingAccountManagement = false } }
      do {
        try await server.sessionControl(threadID: id, operation: "manage-accounts")
        guard generation == current else { return }
        statusText = "已提交 /accounts；需要安装 account-usage 扩展，请等待 Pi 的回复或对话框。"
      } catch {
        guard generation == current else { return }
        statusText = "账户管理未确认；请检查扩展配置，不会自动重试。"
      }
    }
  }

  func applyExtensionUI(_ snapshot: [String: Any]) {
    let epoch = snapshot["epoch"] as? String ?? ""
    if extensionUIEpoch != epoch {
      extensionUIEpoch = epoch
      extensionUISerial = 0
      answeredDialogIDs.removeAll()
    }
    let busy = snapshot["busy"] as? Bool ?? false
    if isManagingAccounts != busy { isManagingAccounts = busy }
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
  func removeQueuedPrompt(id: UUID) { queuedPrompts.removeAll { $0.id == id } }
  func editQueuedPrompt(id: UUID) {
    guard let index = queuedPrompts.firstIndex(where: { $0.id == id }) else { return }
    guard !hasUnsubmittedInput else {
      statusText = "请先发送或清空输入框，避免覆盖尚未提交的草稿。"
      return
    }
    let prompt = queuedPrompts.remove(at: index)
    composerText = prompt.text
    attachments = prompt.attachments
    statusText = "已移出等待队列，编辑后可重新发送。"
  }
  func queuedPromptMoveTarget(id: UUID, direction: Int) -> UUID? {
    guard direction == -1 || direction == 1,
      let index = queuedPrompts.firstIndex(where: { $0.id == id })
    else { return nil }
    let prompt = queuedPrompts[index]
    let candidates =
      direction == -1
      ? Array(queuedPrompts[..<index].reversed()) : Array(queuedPrompts.dropFirst(index + 1))
    return candidates.first {
      $0.delivery == prompt.delivery && $0.waitsForCompaction == prompt.waitsForCompaction
    }?.id
  }
  func moveQueuedPrompt(id: UUID, direction: Int) {
    guard let target = queuedPromptMoveTarget(id: id, direction: direction),
      let from = queuedPrompts.firstIndex(where: { $0.id == id }),
      let to = queuedPrompts.firstIndex(where: { $0.id == target })
    else { return }
    queuedPrompts.swapAt(from, to)
  }
  func editMessage(_ text: String) { composerText = text }
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
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pi-clipboard-\(UUID().uuidString).\(UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "png")"
    )
    do {
      try data.write(to: url)
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

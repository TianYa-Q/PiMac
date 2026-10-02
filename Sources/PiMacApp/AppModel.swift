import AppKit
import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
  @Published var connectionState: ConnectionState = .disconnected {
    didSet { if connectionState == .connected { scheduleCodexAccountRotation() } }
  }
  @Published var projectURL: URL?
  @Published var messages: [ChatEntry] = [] {
    didSet { cachedConversationTurns = nil }
  }
  private var cachedConversationTurns: [ConversationTurn]?

  var conversationTurns: [ConversationTurn] {
    if let cachedConversationTurns { return cachedConversationTurns }
    let turns = ConversationTurn.group(messages)
    cachedConversationTurns = turns
    return turns
  }
  /// Models shown in the composer. `allModels` also contains models hidden by Pi's enabledModels setting.
  @Published var models: [PiModel] = []
  @Published var allModels: [PiModel] = []
  @Published var modelDefaultThinkingLevels: [String: String] = [:]
  @Published var globalDefaultThinkingLevel = "medium"
  @Published var compactionModelID: String?
  @Published var defaultModelID: String? = UserDefaults.standard.string(
    forKey: "defaultNewSessionModelID")
  @Published var selectedModelId = "" {
    didSet {
      scheduleCodexAccountRotation()
      if oldValue != selectedModelId {
        onTelegramLifecycleEvent?(
          "model_changed from=\(oldValue.isEmpty ? "none" : oldValue) to=\(selectedModelId)")
      }
    }
  }
  @Published var thinkingLevels = ["off"]
  @Published var selectedThinkingLevel = "off"
  @Published private(set) var fastModeEnabled = false
  @Published private(set) var fastModeAvailable = false
  @Published private(set) var isChangingFastMode = false
  @Published private(set) var outputTokensPerSecond: Double?
  @Published private(set) var streamActivity = StreamActivity()
  private var outputSpeedTracker = OutputSpeedTracker()
  private var lastOutputSpeedPublish: TimeInterval = 0

  var supportsFastMode: Bool {
    selectedModel.map {
      ($0.provider == "openai-codex" && $0.api != "pi-virtual")
        || ($0.provider == "openai" && $0.api == "openai-responses")
    } ?? false
  }

  var accountUsageProvider: AccountUsageProvider? {
    guard let model = selectedModel, model.api != "pi-virtual" else { return nil }
    return AccountUsageProvider(rawValue: model.provider)
  }

  /// Read-only quota refresh and opening the manager do not interrupt the agent.
  var canManageAccounts: Bool {
    connectionState == .connected && !isLoadingConfiguration
  }

  var supportsAccountSwitch: Bool {
    guard let provider = accountUsageProvider else { return false }
    // The v1 extension only reported legacy Codex accounts, without capabilities.
    return provider == .legacyCodex || extensionUI?.supportsAccountSwitch(for: self) == true
  }

  var supportsAccountRotation: Bool {
    supportsAccountSwitch
      && (accountUsageProvider == .legacyCodex
        || extensionUI?.managesSelectedAuth(for: self) == true)
  }
  @Published var isStreaming = false {
    didSet {
      if !isStreaming {
        streamActivity = StreamActivity()
        scheduleCodexAccountRotation()
      }
    }
  }
  @Published var isCompacting = false {
    didSet { if !isCompacting { scheduleCodexAccountRotation() } }
  }
  @Published var isLoadingConfiguration = false {
    didSet { if !isLoadingConfiguration { scheduleCodexAccountRotation() } }
  }
  @Published var sessionName = ""
  @Published var sessions: [SessionItem] = []
  @Published var currentSessionPath = ""
  @Published var stats: SessionStats?
  @Published var composerText = ""
  @Published var attachments: [PromptAttachment] = []
  @Published var queuedPrompts: [QueuedPrompt] = []
  @Published var statusText = ""
  @Published var diagnosticText = ""

  weak var extensionUI: ExtensionUIModel?
  var onTelegramLifecycleEvent: ((String) -> Void)?

  private static let lastProjectPathKey = "lastProjectPath"
  nonisolated private static let defaultModelKey = "defaultNewSessionModelID"

  private let client: PiRPCClient
  private var codexRotationScheduled = false
  @Published private(set) var codexRotationInFlight = false
  private let codexHandoff = CodexAccountHandoff()
  private var lastCodexRotationAttempt: Date?
  private let remembersDesktopProject: Bool
  private var pendingStartupSessionPath: String?
  private let modelPreferenceKey: String
  private let thinkingPreferenceKey: String?
  private var activeAssistantId: String?
  private var activeThinkingId: String?
  private var activeCompactionId: String?
  private var sessionLoadGeneration = UUID()
  @Published private var isRewritingQueue = false
  @Published private(set) var awaitingAgentStart = false
  private var submittingQueuedPrompts: [UUID: Int] = [:]
  private var consumedPromptsAwaitingDisplay: [QueuedPrompt] = []
  private var pendingAssistantError: String?
  private var queueSnapshotGeneration = 0
  private var latestQueueSnapshot: (steering: [String], followUp: [String])?
  private var thinkingConfigurationGeneration = 0
  private var transcriptLoadGeneration = 0
  private var transcriptLoadInFlightKey: String?
  private var loadedTranscriptKey: String?
  private var loadedTranscriptPath: String?
  private var statsRefreshScheduled = false
  private var pendingMessageDeltas: [String: String] = [:]
  private var messageDeltaFlushScheduled = false
  private var messageDeltaFlushGeneration = 0
  /// Invalidates startup callbacks and timeout tasks when an RPC process is replaced.
  private var connectionGeneration = UUID() {
    didSet {
      codexHandoff.reset()
      fastModeAvailable = false
      isChangingFastMode = false
      outputSpeedTracker.reset()
      outputTokensPerSecond = nil
      codexRotationInFlight = false
      lastCodexRotationAttempt = nil
    }
  }

  private var selectedModel: PiModel? {
    allModels.first { $0.id == selectedModelId }
  }

  var piPath: String {
    get { UserDefaults.standard.string(forKey: "piPath") ?? Self.suggestedPiPath() }
    set {
      UserDefaults.standard.set(newValue, forKey: "piPath")
      objectWillChange.send()
    }
  }

  init(
    startupProjectURL: URL? = nil,
    continueLastSession: Bool = true,
    startupSessionPath: String? = nil,
    restoreLastProjectOnLaunch: Bool = true,
    initialComposerText: String = "",
    remembersDesktopProject: Bool = true,
    modelPreferenceKey: String = "defaultNewSessionModelID",
    thinkingPreferenceKey: String? = nil,
    rpcClient: PiRPCClient = PiRPCClient()
  ) {
    self.client = rpcClient
    self.remembersDesktopProject = remembersDesktopProject
    self.pendingStartupSessionPath = startupSessionPath
    self.modelPreferenceKey = modelPreferenceKey
    self.thinkingPreferenceKey = thinkingPreferenceKey
    fastModeEnabled = UserDefaults.standard.bool(forKey: modelPreferenceKey + ".fastMode")
    // The workspace already knows the target project when constructing a tab. Publish it
    // synchronously so persistent chrome (project/session sidebar) never observes a temporary
    // nil project while the RPC connection is deferred to the next main-actor turn.
    projectURL = startupProjectURL?.standardizedFileURL
    composerText = initialComposerText

    client.onEvent = { [weak self] event in self?.handle(event) }
    client.onErrorOutput = { [weak self] line in
      self?.appendDiagnostic("stderr: \(line)")
    }
    client.onLog = { [weak self] line in
      self?.appendDiagnostic(line)
    }
    client.onTermination = { [weak self] code in
      guard let self else { return }
      self.isStreaming = false
      self.awaitingAgentStart = false
      self.isCompacting = false
      self.isLoadingConfiguration = false
      self.statusText = ""
      if case .disconnected = self.connectionState { return }
      self.connectionState = .failed("Pi 进程退出，状态码 \(code)")
    }

    Task { @MainActor [weak self] in
      await Task.yield()
      // A tab may have been selected again before this deferred startup runs. In that case
      // resumeProcess has already connected it; do not stop and restart the same RPC process.
      guard self?.isProcessRunning != true else { return }
      if let startupProjectURL {
        if let startupSessionPath {
          self?.connect(
            to: startupProjectURL,
            continueLastSession: continueLastSession,
            sessionPath: startupSessionPath
          )
          // 本地 JSONL 读取与 RPC 配置请求并行进行；后续 get_state/get_messages 会复用
          // 这次加载，避免大会话在启动时被重复解析。
          self?.loadCompleteTranscript(at: startupSessionPath)
        } else {
          self?.connect(
            to: startupProjectURL,
            continueLastSession: continueLastSession,
            sessionPath: nil
          )
        }
      } else if restoreLastProjectOnLaunch {
        self?.restoreLastProject()
      }
    }
  }

  func connect(to projectURL: URL, continueLastSession: Bool = true) {
    connect(to: projectURL, continueLastSession: continueLastSession, sessionPath: nil)
  }

  private func connect(
    to projectURL: URL,
    continueLastSession: Bool,
    sessionPath: String?,
    preservingState: Bool = false
  ) {
    guard FileManager.default.fileExists(atPath: projectURL.path) else {
      connectionState = .failed("项目目录不存在")
      return
    }
    guard FileManager.default.isExecutableFile(atPath: piPath) else {
      connectionState = .failed("找不到可执行的 Pi，请在设置中选择 pi 文件")
      return
    }

    pendingStartupSessionPath = nil
    let generation = UUID()
    connectionGeneration = generation
    connectionState = .connecting
    isLoadingConfiguration = true
    statusText = sessionPath == nil ? "正在启动 Pi…" : "正在打开会话…"
    if !preservingState {
      resetTranscriptLoading()
      messages.removeAll()
      queuedPrompts.removeAll()
      submittingQueuedPrompts.removeAll()
      consumedPromptsAwaitingDisplay.removeAll()
      pendingAssistantError = nil
      queueSnapshotGeneration = 0
      latestQueueSnapshot = nil
      diagnosticText = ""
      discardPendingMessageDeltas()
    }
    self.projectURL = projectURL
    // Install/update the companion before Pi starts so this process loads the same extension
    // version that writes compression-model metadata into session records.
    try? PiSettingsStore.installCompactionExtension()
    do {
      try client.start(
        piPath: piPath,
        workingDirectory: projectURL,
        continueLastSession: continueLastSession,
        fastMode: fastModeEnabled
      )
      if remembersDesktopProject {
        UserDefaults.standard.set(projectURL.path, forKey: Self.lastProjectPathKey)
      }
      if let sessionPath {
        currentSessionPath = sessionPath
        client.request(["type": "switch_session", "sessionPath": sessionPath]) {
          [weak self] result in
          guard let self else { return }
          switch result {
          case .failure(let error):
            guard self.connectionGeneration == generation else { return }
            self.appendSystemError(error.localizedDescription)
            self.refreshAll(startupGeneration: generation)
          case .success(let response):
            let cancelled = (response["data"] as? PiRPCClient.JSON)?["cancelled"] as? Bool ?? false
            if !cancelled, self.connectionGeneration == generation {
              self.refreshAll(startupGeneration: generation)
            }
          }
        }
      } else if !continueLastSession {
        selectPreferredModelForNewSession(generation: generation)
      } else {
        refreshAll(startupGeneration: generation)
      }
      startConfigurationTimeout(for: generation)
    } catch {
      isLoadingConfiguration = false
      statusText = ""
      connectionState = .failed(error.localizedDescription)
    }
  }

  var isProcessRunning: Bool { client.isRunning }
  var isBusy: Bool { isStreaming || isCompacting || codexRotationInFlight || isChangingFastMode }
  var canRestartSafely: Bool {
    !isBusy && !awaitingAgentStart && !isLoadingConfiguration && queuedPrompts.isEmpty
      && submittingQueuedPrompts.isEmpty && !isRewritingQueue
  }
  var canReloadModelList: Bool {
    client.isRunning && !isBusy && !isLoadingConfiguration && queuedPrompts.isEmpty
      && projectURL != nil
  }

  var hasUnsubmittedInput: Bool {
    !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
  }

  /// Stop an idle RPC process without discarding the session's transcript, composer draft,
  /// attachments, or extension snapshot. Selecting the session starts a replacement process.
  func suspendProcess() {
    guard canRestartSafely, client.isRunning else { return }
    connectionGeneration = UUID()
    connectionState = .disconnected
    isLoadingConfiguration = false
    statusText = ""
    client.stop()
  }

  func resumeProcess(sessionPath: String?, continueLastSession: Bool) {
    guard !client.isRunning, let projectURL else { return }
    let targetPath =
      sessionPath
      ?? (currentSessionPath.isEmpty
        ? pendingStartupSessionPath : currentSessionPath)
    connect(
      to: projectURL,
      continueLastSession: targetPath == nil ? continueLastSession : false,
      sessionPath: targetPath,
      preservingState: true
    )
  }

  func disconnect() {
    connectionGeneration = UUID()
    extensionUI?.removeRequests(from: self)
    connectionState = .disconnected
    isStreaming = false
    awaitingAgentStart = false
    isCompacting = false
    isLoadingConfiguration = false
    queuedPrompts = []
    submittingQueuedPrompts.removeAll()
    consumedPromptsAwaitingDisplay.removeAll()
    pendingAssistantError = nil
    queueSnapshotGeneration = 0
    latestQueueSnapshot = nil
    discardPendingMessageDeltas()
    sessions = []
    currentSessionPath = ""
    client.stop()
  }

  var hasUserMessage: Bool {
    messages.contains { $0.kind == .user }
  }

  /// 新建任务在用户首次发送消息前只是草稿。离开草稿时停止进程并清理 Pi
  /// 可能提前创建的仅含会话头、模型配置等信息的 JSONL 文件。
  func discardEmptyDraft() {
    guard !hasUserMessage, !isBusy else { return }
    let path = currentSessionPath
    disconnect()
    guard !path.isEmpty else { return }
    try? FileManager.default.removeItem(atPath: path)
  }

  @discardableResult
  func addPastedImage(_ data: Data, mimeType: String) -> [PromptAttachment] {
    let fileExtension = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "png"
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let url = directory.appendingPathComponent("pi-clipboard-\(UUID().uuidString).\(fileExtension)")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      return addAttachments([url])
    } catch {
      appendSystemError("无法保存剪贴板图片：\(error.localizedDescription)")
      return []
    }
  }

  @discardableResult
  func addAttachments(_ urls: [URL]) -> [PromptAttachment] {
    let existing = Set(attachments.map { $0.url.standardizedFileURL })
    let additions =
      urls
      .map(\.standardizedFileURL)
      .filter { $0.isFileURL && !existing.contains($0) }
      .map {
        PromptAttachment(
          url: $0,
          mimeType: UTType(filenameExtension: $0.pathExtension)?.preferredMIMEType
        )
      }
    guard !additions.isEmpty else { return [] }
    attachments.append(contentsOf: additions)
    return additions
  }

  func removeAttachment(_ attachment: PromptAttachment) {
    attachments.removeAll { $0.id == attachment.id }
  }

  func editMessage(_ text: String) {
    composerText = text
  }

  func sendPrompt(delivery: QueuedPromptDelivery = .steer) {
    guard canSubmitPrompt,
      let prompt = Self.makePrompt(composerText, attachments: attachments, delivery: delivery)
    else { return }
    composerText = ""
    attachments = []
    submitPrompt(prompt)
  }

  func removeQueuedPrompt(id: UUID) {
    dequeuePrompt(id: id)
  }

  func editQueuedPrompt(id: UUID) {
    dequeuePrompt(id: id) { [weak self] prompt in
      guard let self else { return }
      if self.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        self.composerText = prompt.text
      } else {
        // Do not silently discard a draft that was started after this prompt was queued.
        self.composerText = prompt.text + "\n\n" + self.composerText
      }
      let attachedURLs = Set(self.attachments.map { $0.url.standardizedFileURL })
      self.attachments.insert(
        contentsOf: prompt.attachments.filter {
          !attachedURLs.contains($0.url.standardizedFileURL)
        },
        at: 0
      )
    }
  }

  func queuedPromptMoveTarget(id: UUID, direction: Int) -> UUID? {
    guard !isRewritingQueue, submittingQueuedPrompts.isEmpty,
      let index = queuedPrompts.firstIndex(where: { $0.id == id }),
      direction == -1 || direction == 1
    else { return nil }
    let prompt = queuedPrompts[index]
    let candidates =
      direction < 0
      ? Array(queuedPrompts[..<index].reversed())
      : Array(queuedPrompts.dropFirst(index + 1))
    return candidates.first {
      $0.delivery == prompt.delivery && $0.waitsForCompaction == prompt.waitsForCompaction
    }?.id
  }

  func moveQueuedPrompt(id: UUID, direction: Int) {
    guard let destination = queuedPromptMoveTarget(id: id, direction: direction) else { return }
    dequeuePrompt(id: id, swappingWith: destination)
  }

  private func dequeuePrompt(
    id: UUID, swappingWith destination: UUID? = nil,
    onRemoved: ((QueuedPrompt) -> Void)? = nil
  ) {
    guard let target = queuedPrompts.first(where: { $0.id == id }),
      !isRewritingQueue, submittingQueuedPrompts[id] == nil
    else { return }
    if target.waitsForCompaction {
      if let destination,
        let sourceIndex = queuedPrompts.firstIndex(where: { $0.id == id }),
        let destinationIndex = queuedPrompts.firstIndex(where: { $0.id == destination })
      {
        queuedPrompts.swapAt(sourceIndex, destinationIndex)
      } else if destination == nil {
        queuedPrompts.removeAll { $0.id == id }
        onRemoved?(target)
      }
      return
    }
    isRewritingQueue = true
    client.request(["type": "clear_queue"]) { [weak self] result in
      guard let self else { return }
      guard case .success(let response) = result,
        let data = response["data"] as? PiRPCClient.JSON
      else {
        self.isRewritingQueue = false
        if case .failure(let error) = result { self.appendSystemError(error.localizedDescription) }
        return
      }

      var steering = (data["steering"] as? [String]) ?? []
      var followUp = (data["followUp"] as? [String]) ?? []
      var stillQueued: [QueuedPrompt] = []
      var removedTarget: QueuedPrompt?
      for prompt in self.queuedPrompts {
        if prompt.waitsForCompaction {
          stillQueued.append(prompt)
          continue
        }
        var values = prompt.delivery == .steer ? steering : followUp
        guard let index = values.firstIndex(of: prompt.rpcText) else {
          // It left Pi's queue before clear_queue ran and can no longer be changed.
          // Defer its chat row until Pi starts producing the response to it.
          self.consumedPromptsAwaitingDisplay.append(prompt)
          continue
        }
        values.remove(at: index)
        if prompt.delivery == .steer { steering = values } else { followUp = values }
        if prompt.id == target.id && destination == nil {
          removedTarget = prompt
        } else {
          stillQueued.append(prompt)
        }
      }

      // Only move messages that clear_queue confirmed are still pending.
      if let destination,
        let sourceIndex = stillQueued.firstIndex(where: { $0.id == id }),
        let destinationIndex = stillQueued.firstIndex(where: { $0.id == destination })
      {
        stillQueued.swapAt(sourceIndex, destinationIndex)
      }
      self.queuedPrompts = stillQueued
      if let removedTarget { onRemoved?(removedTarget) }
      let remotePrompts = stillQueued.filter { !$0.waitsForCompaction }
      guard !remotePrompts.isEmpty else {
        self.isRewritingQueue = false
        self.latestQueueSnapshot = (steering, followUp)
        return
      }

      // Use the reconstructed queue if Pi does not emit queue_update during requeueing.
      self.latestQueueSnapshot = (
        remotePrompts.filter { $0.delivery == .steer }.map(\.rpcText),
        remotePrompts.filter { $0.delivery == .followUp }.map(\.rpcText)
      )
      var remaining = remotePrompts.count
      for prompt in remotePrompts {
        self.sendQueuedPrompt(prompt) { [weak self] requeueResult in
          guard let self else { return }
          if case .failure(let error) = requeueResult {
            self.queuedPrompts.removeAll { $0.id == prompt.id }
            self.appendSystemError("重新排队失败：\(error.localizedDescription)")
          }
          remaining -= 1
          if remaining == 0 {
            self.isRewritingQueue = false
            if let snapshot = self.latestQueueSnapshot {
              self.reconcileQueue(steering: snapshot.steering, followUp: snapshot.followUp)
            }
          }
        }
      }
    }
  }

  func abort() {
    if codexRotationInFlight {
      codexHandoff.cancel()
      statusText = "正在停止，已取消账户切换后的自动继续…"
      return
    }
    isRewritingQueue = true
    client.request(["type": "clear_queue"]) { [weak self] result in
      guard let self else { return }
      if case .success(let response) = result,
        let data = response["data"] as? PiRPCClient.JSON
      {
        let queued =
          ((data["steering"] as? [String]) ?? []) + ((data["followUp"] as? [String]) ?? [])
        let deferred = self.queuedPrompts.filter(\.waitsForCompaction).map(\.text)
        let restored = queued + deferred
        if !restored.isEmpty { self.composerText = restored.joined(separator: "\n") }
        self.attachments.append(contentsOf: self.queuedPrompts.flatMap(\.attachments))
      }
      self.queuedPrompts = []
      self.submittingQueuedPrompts.removeAll()
      self.latestQueueSnapshot = ([], [])
      self.isRewritingQueue = false
      self.client.request(["type": "abort"])
    }
  }

  /// Remote input must not consume or overwrite the local composer draft and attachments.
  func sendRemotePrompt(
    _ text: String, attachments: [PromptAttachment] = [], messageID: String? = nil,
    completion: @escaping (Bool) -> Void
  ) {
    guard canSubmitPrompt, !isBusy, queuedPrompts.isEmpty,
      let prompt = Self.makePrompt(text, attachments: attachments, delivery: .steer)
    else {
      completion(false)
      return
    }
    submitImmediatePrompt(prompt, messageID: messageID, completion: completion)
  }

  var canSubmitPrompt: Bool {
    clientConnectedForCommands && client.isRunning && !isLoadingConfiguration && !isRewritingQueue
  }

  /// Normalize every input identically, regardless of transport. Composer state is not touched.
  nonisolated static func makePrompt(
    _ text: String, attachments: [PromptAttachment], delivery: QueuedPromptDelivery
  ) -> QueuedPrompt? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || !attachments.isEmpty else { return nil }
    let displayText = trimmed.isEmpty ? "请查看附件。" : trimmed
    return QueuedPrompt(
      id: UUID(), text: displayText,
      rpcText: rpcText(for: displayText, attachments: attachments),
      delivery: delivery, attachments: attachments)
  }

  private func submitPrompt(_ prompt: QueuedPrompt, completion: ((Bool) -> Void)? = nil) {
    if isCompacting || codexRotationInFlight {
      var deferred = prompt
      deferred.waitsForCompaction = true
      queuedPrompts.append(deferred)
    } else if isStreaming {
      submitQueuedPrompt(prompt)
    } else {
      submitImmediatePrompt(prompt, completion: completion)
    }
  }

  private func submitImmediatePrompt(
    _ prompt: QueuedPrompt,
    messageID: String? = nil,
    completion: ((Bool) -> Void)? = nil
  ) {
    messages.append(
      ChatEntry(
        id: messageID ?? UUID().uuidString,
        kind: .user,
        title: "你",
        text: prompt.text,
        attachments: prompt.attachments
      ))
    awaitingAgentStart = true
    let generation = connectionGeneration
    client.request(Self.promptCommand(message: prompt.rpcText, attachments: prompt.attachments)) {
      [weak self] result in
      guard let self, self.connectionGeneration == generation else {
        completion?(false)
        return
      }
      switch result {
      case .success(let response):
        self.applyPromptDisposition(response)
        completion?(true)
      case .failure(let error):
        self.awaitingAgentStart = false
        self.appendSystemError(error.localizedDescription)
        completion?(false)
      }
    }
  }

  private func submitQueuedPrompt(_ prompt: QueuedPrompt) {
    var submitted = prompt
    submitted.waitsForCompaction = false
    if let index = queuedPrompts.firstIndex(where: { $0.id == submitted.id }) {
      queuedPrompts[index] = submitted
    } else {
      queuedPrompts.append(submitted)
    }
    let submittedAtGeneration = queueSnapshotGeneration
    submittingQueuedPrompts[submitted.id] = submittedAtGeneration
    let generation = connectionGeneration
    sendQueuedPrompt(submitted) { [weak self] result in
      guard let self, self.connectionGeneration == generation else { return }
      self.submittingQueuedPrompts.removeValue(forKey: submitted.id)
      switch result {
      case .success:
        if self.queueSnapshotGeneration > submittedAtGeneration,
          let snapshot = self.latestQueueSnapshot
        {
          self.reconcileQueue(steering: snapshot.steering, followUp: snapshot.followUp)
        }
      case .failure(let error):
        self.queuedPrompts.removeAll { $0.id == submitted.id }
        if self.composerText.isEmpty { self.composerText = submitted.text }
        self.attachments.append(contentsOf: submitted.attachments)
        self.appendSystemError(error.localizedDescription)
      }
    }
  }

  private func sendQueuedPrompt(
    _ prompt: QueuedPrompt,
    completion: ((Result<PiRPCClient.JSON, Error>) -> Void)? = nil
  ) {
    var command = Self.promptCommand(message: prompt.rpcText, attachments: prompt.attachments)
    command["streamingBehavior"] = prompt.delivery.rawValue
    let generation = connectionGeneration
    client.request(command) { [weak self] result in
      guard let self, self.connectionGeneration == generation else {
        completion?(.failure(RPCError.cancelled))
        return
      }
      if case .success(let response) = result {
        self.applyPromptDisposition(response, queuedPromptID: prompt.id)
      }
      completion?(result)
    }
  }

  /// Acceptance is per input, not per run: handled commands/inputs never promise
  /// agent_start or agent_settled. Missing disposition preserves older Pi behavior.
  func applyPromptDisposition(_ response: PiRPCClient.JSON, queuedPromptID: UUID? = nil) {
    let disposition = (response["data"] as? PiRPCClient.JSON)?["disposition"] as? String
    if let id = queuedPromptID, disposition == "handled" || disposition == "started" {
      if let prompt = queuedPrompts.first(where: { $0.id == id }), disposition == "started" {
        consumedPromptsAwaitingDisplay.append(prompt)
      }
      queuedPrompts.removeAll { $0.id == id }
      consumedPromptsAwaitingDisplay.removeAll { $0.id == id && disposition == "handled" }
    } else if queuedPromptID == nil, disposition == "handled" || disposition == "queued" {
      awaitingAgentStart = false
    }
  }

  private func flushCompactionQueue(willRetry: Bool) {
    guard !codexRotationInFlight else { return }
    let deferred = queuedPrompts.filter(\.waitsForCompaction)
    guard !deferred.isEmpty else { return }

    if willRetry || isStreaming {
      for prompt in deferred { submitQueuedPrompt(prompt) }
      return
    }

    let first = deferred[0]
    queuedPrompts.removeAll { $0.id == first.id }
    submitImmediatePrompt(first) { [weak self] accepted in
      guard let self else { return }
      if accepted {
        for prompt in deferred.dropFirst() { self.submitQueuedPrompt(prompt) }
      } else {
        self.queuedPrompts.removeAll { deferred.dropFirst().map(\.id).contains($0.id) }
        if self.composerText.isEmpty {
          self.composerText = deferred.map(\.text).joined(separator: "\n\n")
        }
        self.attachments.append(contentsOf: deferred.flatMap(\.attachments))
      }
    }
  }

  nonisolated static func rpcText(
    for displayText: String, attachments: [PromptAttachment]
  ) -> String {
    let filePaths = attachments.filter { !$0.isImage }.map(\.url.path)
    guard !filePaths.isEmpty else { return displayText }
    return displayText
      + "\n\n<pi-mac-attached-files>\n"
      + filePaths.joined(separator: "\n")
      + "\n</pi-mac-attached-files>"
  }

  nonisolated private static func promptCommand(
    message: String, attachments: [PromptAttachment]
  ) -> PiRPCClient.JSON {
    var command: PiRPCClient.JSON = ["type": "prompt", "message": message]
    let images: [PiRPCClient.JSON] = attachments.compactMap { attachment in
      guard attachment.isImage,
        let mimeType = attachment.mimeType,
        let data = try? Data(contentsOf: attachment.url),
        data.count <= 20 * 1_024 * 1_024
      else { return nil }
      return ["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType]
    }
    if !images.isEmpty { command["images"] = images }
    return command
  }

  var canReuseProcessForNewSession: Bool {
    client.isRunning && !isBusy && !isLoadingConfiguration
      && queuedPrompts.isEmpty && clientConnectedForCommands
  }

  func newSession(completion: ((Bool) -> Void)? = nil) {
    guard canReuseProcessForNewSession
    else {
      completion?(false)
      return
    }

    // Switch the visible document immediately. The RPC process can finish resetting in the
    // background; keeping the previous transcript on screen made New Task feel blocked on Pi.
    // Retain enough state to put the old session back if Pi rejects the request.
    let previousMessages = messages
    let previousSessionName = sessionName
    let previousStats = stats
    let previousSessionPath = currentSessionPath
    let previousLoadedTranscriptKey = loadedTranscriptKey
    let previousLoadedTranscriptPath = loadedTranscriptPath

    let generation = UUID()
    connectionGeneration = generation
    connectionState = .connecting
    isLoadingConfiguration = true
    statusText = "正在新建任务…"
    messages.removeAll()
    queuedPrompts.removeAll()
    submittingQueuedPrompts.removeAll()
    consumedPromptsAwaitingDisplay.removeAll()
    pendingAssistantError = nil
    queueSnapshotGeneration = 0
    latestQueueSnapshot = nil
    sessionName = ""
    stats = nil
    currentSessionPath = ""
    resetTranscriptLoading()
    extensionUI?.sessionWillChange(for: self)

    let restorePreviousSession = { [weak self] in
      guard let self else { return }
      self.messages = previousMessages
      self.sessionName = previousSessionName
      self.stats = previousStats
      self.currentSessionPath = previousSessionPath
      self.loadedTranscriptKey = previousLoadedTranscriptKey
      self.loadedTranscriptPath = previousLoadedTranscriptPath
      self.transcriptLoadInFlightKey = nil
      self.extensionUI?.cancelSessionChange(for: self)
      self.isLoadingConfiguration = false
      self.connectionState = .connected
      self.statusText = ""
    }

    client.request(["type": "new_session"]) { [weak self] result in
      guard let self, self.connectionGeneration == generation else { return }
      switch result {
      case .failure(let error):
        restorePreviousSession()
        self.appendSystemError(error.localizedDescription)
        completion?(false)
      case .success(let response):
        let cancelled = (response["data"] as? PiRPCClient.JSON)?["cancelled"] as? Bool ?? false
        guard !cancelled else {
          restorePreviousSession()
          completion?(false)
          return
        }
        self.selectPreferredModelForNewSession(generation: generation) {
          completion?(true)
        }
        self.startConfigurationTimeout(for: generation)
      }
    }
  }

  func switchSession(
    path: String, in project: URL? = nil, completion: ((Bool) -> Void)? = nil
  ) {
    guard canReuseProcessForNewSession else {
      statusText = "当前任务进行中或会话尚未就绪，暂时不能切换会话"
      completion?(false)
      return
    }
    let previousProject = projectURL
    let previousSessions = sessions
    let previousPath = currentSessionPath
    let previousMessages = messages
    let previousName = sessionName
    let previousStats = stats
    let generation = UUID()
    connectionGeneration = generation
    isLoadingConfiguration = true
    statusText = "正在切换会话…"
    resetTranscriptLoading()
    if let project, project.standardizedFileURL != projectURL?.standardizedFileURL {
      projectURL = project.standardizedFileURL
      sessions = []
    }
    currentSessionPath = path
    messages.removeAll()
    sessionName = ""
    stats = nil
    // Show persisted history without waiting for Pi's switch_session and configuration RPCs.
    loadCompleteTranscript(at: path)
    client.request(["type": "switch_session", "sessionPath": path]) { [weak self] result in
      guard let self, self.connectionGeneration == generation else { return }
      self.isLoadingConfiguration = false
      self.statusText = ""
      switch result {
      case .failure(let error):
        self.resetTranscriptLoading()
        self.projectURL = previousProject
        self.sessions = previousSessions
        self.currentSessionPath = previousPath
        self.messages = previousMessages
        self.sessionName = previousName
        self.stats = previousStats
        self.appendSystemError(error.localizedDescription)
        completion?(false)
      case .success(let response):
        let cancelled = (response["data"] as? PiRPCClient.JSON)?["cancelled"] as? Bool ?? false
        guard !cancelled else {
          self.resetTranscriptLoading()
          self.projectURL = previousProject
          self.sessions = previousSessions
          self.currentSessionPath = previousPath
          self.messages = previousMessages
          self.sessionName = previousName
          self.stats = previousStats
          completion?(false)
          return
        }
        if let project, self.remembersDesktopProject {
          UserDefaults.standard.set(
            project.standardizedFileURL.path, forKey: Self.lastProjectPathKey)
        }
        self.refreshAll()
        completion?(true)
      }
    }
  }

  func changeModel(to id: String) {
    guard let model = allModels.first(where: { $0.id == id }) else { return }
    if id == selectedModelId {
      // Explicitly choosing the current remote model should also pin it for future sessions.
      if thinkingPreferenceKey != nil { UserDefaults.standard.set(id, forKey: modelPreferenceKey) }
      return
    }
    client.request(["type": "set_model", "provider": model.provider, "modelId": model.modelId]) {
      [weak self] result in
      switch result {
      case .success:
        guard let self else { return }
        self.selectedModelId = id
        if self.thinkingPreferenceKey != nil {
          UserDefaults.standard.set(id, forKey: self.modelPreferenceKey)
        }
        // Pi's settings manager may still hold the defaults from process startup.
        // Apply the latest per-model or global default explicitly in that case.
        self.applySavedThinkingLevel(for: model.id) { [weak self] in
          self?.synchronizeThinkingConfiguration(expectedModelID: id)
        }
      case .failure(let error): self?.appendSystemError(error.localizedDescription)
      }
    }
  }

  func changeThinkingLevel(to level: String) {
    guard thinkingLevels.contains(level) else { return }
    if level == selectedThinkingLevel {
      if let key = thinkingPreferenceKey {
        var levels = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        levels[selectedModelId] = level
        UserDefaults.standard.set(levels, forKey: key)
      }
      return
    }
    client.request(["type": "set_thinking_level", "level": level]) { [weak self] result in
      switch result {
      case .success:
        guard let self else { return }
        if let key = self.thinkingPreferenceKey {
          var levels = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
          levels[self.selectedModelId] = level
          UserDefaults.standard.set(levels, forKey: key)
        }
        // Pi may clamp a requested value to model capabilities. get_state is authoritative.
        self.synchronizeThinkingConfiguration(expectedModelID: self.selectedModelId)
      case .failure(let error): self?.appendSystemError(error.localizedDescription)
      }
    }
  }

  func setModelVisible(_ visible: Bool, modelID: String) {
    var visibleIDs = Set(models.map(\.id))
    if visible { visibleIDs.insert(modelID) } else { visibleIDs.remove(modelID) }
    guard !visibleIDs.isEmpty else {
      statusText = "至少需要保留一个可见模型"
      return
    }
    do {
      let orderedIDs = allModels.map(\.id).filter { visibleIDs.contains($0) }
      try PiSettingsStore.setEnabledModelIDs(orderedIDs)
      applyModelPreferences()
    } catch {
      appendSystemError("保存模型显示设置失败：\(error.localizedDescription)")
    }
  }

  func setDefaultModel(_ modelID: String?) {
    if let modelID, !allModels.contains(where: { $0.id == modelID }) { return }
    UserDefaults.standard.set(modelID, forKey: Self.defaultModelKey)
    defaultModelID = modelID
    statusText = "默认模型已保存；将在新建会话时生效"
  }

  func setGlobalDefaultThinkingLevel(_ level: String) {
    guard PiModel.thinkingLevelOrder.contains(level) else { return }
    do {
      try PiSettingsStore.setDefaultThinkingLevel(level)
      applyModelPreferences()
      statusText = "全局默认思考等级已保存；将在切换模型或新建会话时生效"
    } catch {
      appendSystemError("保存全局默认思考等级失败：\(error.localizedDescription)")
    }
  }

  func setDefaultThinkingLevel(_ level: String?, for modelID: String) {
    do {
      try PiSettingsStore.setThinkingLevel(level, for: modelID)
      applyModelPreferences()
      if modelID == selectedModelId {
        statusText = "默认值将在下次切换到该模型或新建会话时生效"
      }
    } catch {
      appendSystemError("保存模型默认思考等级失败：\(error.localizedDescription)")
    }
  }

  func setCompactionModel(_ modelID: String?) {
    do {
      let model = modelID.flatMap { id in allModels.first(where: { $0.id == id }) }
      try PiSettingsStore.setCompactionModel(model)
      compactionModelID = model?.id
      reloadRPCProcessForCompactionModel()
    } catch {
      appendSystemError("保存压缩模型失败：\(error.localizedDescription)")
    }
  }

  func reloadModelList() {
    guard canReloadModelList, let projectURL else {
      statusText = "请等待当前任务完成后再重新载入模型列表"
      return
    }

    let sessionPath = currentSessionPath.isEmpty ? nil : currentSessionPath
    extensionUI?.removeRequests(from: self)
    connectionState = .disconnected
    client.stop()
    connect(
      to: projectURL,
      continueLastSession: sessionPath == nil,
      sessionPath: sessionPath,
      preservingState: true
    )
  }

  private func reloadRPCProcessForCompactionModel() {
    guard client.isRunning else {
      statusText = "压缩模型已保存，将在下次连接时生效"
      return
    }
    guard !isBusy, queuedPrompts.isEmpty, let projectURL else {
      statusText = "压缩模型已保存，将在当前任务结束并重新打开会话后生效"
      return
    }

    let sessionPath = currentSessionPath.isEmpty ? nil : currentSessionPath
    extensionUI?.removeRequests(from: self)
    connectionState = .disconnected
    client.stop()
    connect(
      to: projectURL,
      continueLastSession: sessionPath == nil,
      sessionPath: sessionPath,
      preservingState: true
    )
  }

  /// Recheck after the current RPC event finishes, then hand off an active run if needed.
  func scheduleCodexAccountRotation() {
    guard !codexRotationScheduled else { return }
    codexRotationScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.codexRotationScheduled = false
      self.rotateCodexAccountIfNeeded()
    }
  }

  private func rotateCodexAccountIfNeeded() {
    guard connectionState == .connected, client.isRunning,
      !isLoadingConfiguration, !awaitingAgentStart, !isRewritingQueue,
      submittingQueuedPrompts.isEmpty, !codexRotationInFlight,
      supportsAccountRotation,
      let usage = extensionUI?.usage(for: self), usage.gemini?.isActive != true,
      let target = CodexAccountRotation.nextAccount(in: usage.accounts)
    else { return }
    // Repeated status events and failures must not create a rapid switch/retry loop.
    let now = Date()
    guard lastCodexRotationAttempt.map({ now.timeIntervalSince($0) >= 60 }) ?? true
    else { return }
    lastCodexRotationAttempt = now
    let resume = isStreaming
    let interrupt = isStreaming || isCompacting
    codexRotationInFlight = true
    isRewritingQueue = true
    let generation = connectionGeneration
    statusText = "5h 额度低于 5%，正在停止当前执行并切换到 \(target)…"
    codexHandoff.start(
      target: target, interrupt: interrupt,
      request: { [weak self] command, completion in
        self?.client.request(command, completion: completion)
      },
      preserveQueue: { [weak self] data in
        guard let self else { return }
        self.reconcileQueue(
          steering: data["steering"] as? [String] ?? [],
          followUp: data["followUp"] as? [String] ?? [])
        for index in self.queuedPrompts.indices {
          self.queuedPrompts[index].waitsForCompaction = true
        }
        self.latestQueueSnapshot = ([], [])
      },
      verifyAccount: { [weak self] in
        guard let self else { return false }
        return self.extensionUI?.usage(for: self).accounts.first(where: \.isActive)?.name == target
      },
      completion: { [weak self] result in
        guard let self, self.connectionGeneration == generation else { return }
        self.codexRotationInFlight = false
        self.isRewritingQueue = false
        self.statusText = ""
        switch result {
        case .success:
          if resume {
            // Keep the logical run active across the handoff, including for Telegram replies.
            let text =
              "刚才因 OpenAI / Codex 账户额度不足中断，现已切换账户。请基于当前会话上下文继续完成尚未完成的任务；先检查被中断操作的实际结果，不要重复已完成的操作。"
            self.submitImmediatePrompt(
              QueuedPrompt(id: UUID(), text: text, rpcText: text, delivery: .steer, attachments: [])
            ) { [weak self] accepted in
              guard let self, self.connectionGeneration == generation else { return }
              if accepted {
                self.flushCompactionQueue(willRetry: true)
              } else {
                self.isStreaming = false
                self.restoreCodexHandoffQueue()
              }
            }
          } else {
            self.flushCompactionQueue(willRetry: false)
          }
        case .failure(let error):
          // Query actual state: clear_queue/abort may have failed while the agent is still running.
          self.restoreCodexHandoffQueue()
          self.loadState()
          if !(error is CancellationError) {
            self.appendSystemError("自动切换 Codex 账户失败：\(error.localizedDescription)")
          }
        }
      })
  }

  private func restoreCodexHandoffQueue() {
    let held = queuedPrompts.filter(\.waitsForCompaction)
    guard !held.isEmpty else { return }
    let text = held.map(\.text).joined(separator: "\n\n")
    composerText = composerText.isEmpty ? text : composerText + "\n\n" + text
    attachments.append(contentsOf: held.flatMap(\.attachments))
    queuedPrompts.removeAll(where: \.waitsForCompaction)
  }

  func switchCodexAccount(to accountName: String) {
    guard supportsAccountSwitch else {
      statusText = "当前账户扩展未报告此提供商的切换能力，请升级 account-usage"
      return
    }
    guard !isBusy else {
      statusText = "当前任务完成后才能切换 Codex 账户"
      return
    }
    runExtensionCommand(
      "/accounts switch \(accountName)",
      progress: "正在切换到 \(accountName)…"
    )
  }

  func changeFastMode(to enabled: Bool) {
    guard canRestartSafely, supportsFastMode, fastModeAvailable else { return }
    isChangingFastMode = true
    let generation = connectionGeneration
    client.request(["type": "prompt", "message": "/pimac-fast \(enabled ? "on" : "off")"]) {
      [weak self] result in
      guard let self, generation == self.connectionGeneration else { return }
      self.isChangingFastMode = false
      if case .failure(let error) = result { self.appendSystemError(error.localizedDescription) }
    }
  }

  func refreshCodexAccounts() {
    runExtensionCommand("/usage refresh", progress: "正在刷新账户额度…")
  }

  func openCodexAccountManager() {
    runExtensionCommand("/accounts", progress: "正在打开账户管理…")
  }

  private func runExtensionCommand(_ message: String, progress: String) {
    guard client.isRunning else { return }
    statusText = progress
    let generation = connectionGeneration
    client.request(["type": "prompt", "message": message]) { [weak self] result in
      guard let self, self.connectionGeneration == generation else { return }
      self.statusText = ""
      if case .failure(let error) = result { self.appendSystemError(error.localizedDescription) }
    }
  }

  func compact() {
    guard !isBusy else { return }
    isCompacting = true
    statusText = "正在压缩上下文…"
    let generation = connectionGeneration
    client.request(["type": "compact"]) { [weak self] result in
      guard let self, self.connectionGeneration == generation else { return }
      self.isCompacting = false
      self.statusText = ""
      switch result {
      case .success:
        self.loadStats()
        self.refreshSessionMetadata()
      case .failure(let error): self.appendSystemError(error.localizedDescription)
      }
    }
  }

  func sendExtensionResponse(
    id: String,
    value: String? = nil,
    confirmed: Bool? = nil,
    cancelled: Bool = false
  ) {
    var response: PiRPCClient.JSON = ["type": "extension_ui_response", "id": id]
    if cancelled { response["cancelled"] = true }
    if let value { response["value"] = value }
    if let confirmed { response["confirmed"] = confirmed }
    client.sendExtensionResponse(response)
  }

  func appendExtensionNotification(_ text: String) {
    messages.append(
      ChatEntry(
        id: UUID().uuidString, kind: .system, title: "通知",
        text: QuotaNotificationFormatter.format(text))
    )
  }

  private func restoreLastProject() {
    guard let path = UserDefaults.standard.string(forKey: Self.lastProjectPathKey),
      FileManager.default.fileExists(atPath: path)
    else { return }
    connect(to: URL(fileURLWithPath: path, isDirectory: true))
  }

  private func startConfigurationTimeout(for generation: UUID) {
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(15))
      guard let self, self.connectionGeneration == generation,
        self.isLoadingConfiguration
      else { return }
      self.isLoadingConfiguration = false
      self.connectionState = .failed("Pi 启动超时")
      self.statusText = ""
      self.appendSystemError("启动 Pi 超过 15 秒。请展开左侧“诊断日志”查看 RPC 是否返回。")
      self.appendDiagnostic(
        "启动超时：没有收到 get_available_models 的有效响应；待处理 RPC：\(self.client.pendingRequestSummary)"
      )
    }
  }

  // Desktop defaults are configured in model settings, never by session model changes.
  // Telegram keeps its independent last-selection behavior.
  static func preferredNewSessionModelID(
    currentModelID: String, defaults: UserDefaults = .standard,
    preferenceKey: String = defaultModelKey
  ) -> String? {
    let saved = defaults.string(forKey: preferenceKey) ?? ""
    let id = saved.isEmpty && preferenceKey != defaultModelKey ? currentModelID : saved
    let parts = id.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return id
  }

  private func selectPreferredModelForNewSession(
    generation: UUID, completion: (() -> Void)? = nil
  ) {
    let finish: () -> Void = { [weak self] in
      guard let self, self.connectionGeneration == generation else { return }
      self.refreshAll(startupGeneration: generation)
      completion?()
    }
    guard
      let id = Self.preferredNewSessionModelID(
        currentModelID: selectedModelId, preferenceKey: modelPreferenceKey)
    else {
      applySavedThinkingLevelForCurrentModel(generation: generation, completion: finish)
      return
    }
    let parts = id.split(separator: "/", maxSplits: 1)
    client.request([
      "type": "set_model", "provider": String(parts[0]), "modelId": String(parts[1]),
    ]) { [weak self] result in
      guard let self, self.connectionGeneration == generation else { return }
      if case .failure(let error) = result {
        self.appendSystemError("无法为新任务选择默认模型：\(error.localizedDescription)")
      }
      self.applySavedThinkingLevelForCurrentModel(generation: generation, completion: finish)
    }
  }

  private func applySavedThinkingLevelForCurrentModel(
    generation: UUID, completion: @escaping () -> Void
  ) {
    client.request(["type": "get_state"]) { [weak self] result in
      guard let self, self.connectionGeneration == generation else { return }
      guard case .success(let response) = result,
        let state = response["data"] as? PiRPCClient.JSON,
        let model = state["model"] as? PiRPCClient.JSON,
        let provider = model["provider"] as? String,
        let modelID = model["id"] as? String
      else {
        completion()
        return
      }
      self.applySavedThinkingLevel(for: "\(provider)/\(modelID)", completion: completion)
    }
  }

  private func applySavedThinkingLevel(for modelID: String, completion: @escaping () -> Void) {
    let preferences = PiSettingsStore.loadModelPreferences()
    let remoteLevels = thinkingPreferenceKey.flatMap {
      UserDefaults.standard.dictionary(forKey: $0) as? [String: String]
    }
    let level = remoteLevels?[modelID] ?? preferences.thinkingLevel(for: modelID)
    client.request(["type": "set_thinking_level", "level": level]) { [weak self] result in
      if case .failure(let error) = result {
        self?.appendSystemError("应用默认思考等级失败：\(error.localizedDescription)")
      }
      completion()
    }
  }

  private func refreshAll(startupGeneration: UUID? = nil) {
    loadState()
    loadMessages()
    loadModels(startupGeneration: startupGeneration)
    loadThinkingLevels()
    loadStats()
    // Session indexing can read large JSONL files. Do not compete with Pi's initial
    // configuration response; cached sidebar entries remain visible in the meantime.
    if startupGeneration == nil { loadSessions() }
  }

  private func loadState() {
    client.request(["type": "get_state"]) { [weak self] result in
      guard case .success(let response) = result,
        let data = response["data"] as? PiRPCClient.JSON
      else { return }
      self?.selectedThinkingLevel = data["thinkingLevel"] as? String ?? "off"
      if self?.codexRotationInFlight != true {
        self?.isStreaming = data["isStreaming"] as? Bool ?? false
      }
      self?.isCompacting = data["isCompacting"] as? Bool ?? false
      self?.sessionName = data["sessionName"] as? String ?? ""
      let sessionPath = data["sessionFile"] as? String ?? ""
      if self?.currentSessionPath != sessionPath { self?.resetTranscriptLoading() }
      self?.currentSessionPath = sessionPath
      if !sessionPath.isEmpty { self?.loadCompleteTranscript(at: sessionPath) }
      if let model = data["model"] as? PiRPCClient.JSON,
        let provider = model["provider"] as? String,
        let id = model["id"] as? String
      {
        self?.selectedModelId = "\(provider)/\(id)"
      }
    }
  }

  private func loadMessages() {
    client.request(["type": "get_messages"]) { [weak self] result in
      guard let self, case .success(let response) = result,
        let data = response["data"] as? PiRPCClient.JSON,
        let rawMessages = data["messages"] as? [PiRPCClient.JSON]
      else { return }
      self.applyRPCMessageSnapshot(rawMessages)
      if !self.currentSessionPath.isEmpty {
        self.loadCompleteTranscript(at: self.currentSessionPath)
      }
    }
  }

  // RPC get_messages is the model's current context, not the complete session history.
  // Once JSONL has supplied this session, late RPC snapshots must not truncate it,
  // even if the file has since grown and another full-history refresh is pending.
  func applyRPCMessageSnapshot(_ rawMessages: [PiRPCClient.JSON]) {
    guard currentSessionPath.isEmpty || loadedTranscriptPath != currentSessionPath else { return }
    messages = Self.chatEntries(from: rawMessages)
  }

  func applyCompleteTranscript(_ complete: [ChatEntry], at path: String, cacheKey: String) {
    guard currentSessionPath == path, !complete.isEmpty else { return }
    loadedTranscriptKey = cacheKey
    loadedTranscriptPath = path
    TranscriptCache.shared.insert(complete, at: path, key: cacheKey)
    if messages != complete { messages = complete }
  }

  private func resetTranscriptLoading() {
    outputSpeedTracker.reset()
    outputTokensPerSecond = nil
    transcriptLoadGeneration += 1
    transcriptLoadInFlightKey = nil
    loadedTranscriptKey = nil
    loadedTranscriptPath = nil
  }

  /// Another Pi process (e.g. Telegram) may append to the same JSONL session without
  /// producing events on this model's RPC connection.
  func refreshExternalTranscript(at path: String) {
    guard currentSessionPath == path, canRestartSafely else { return }
    loadCompleteTranscript(at: path)
  }

  /// Mirror display data only: the desktop RPC process does not own the remote run.
  func applyRemoteSessionSnapshot(from source: AppModel) {
    guard source !== self, !currentSessionPath.isEmpty,
      currentSessionPath == source.currentSessionPath,
      projectURL?.standardizedFileURL == source.projectURL?.standardizedFileURL,
      canRestartSafely
    else { return }
    if !source.messages.isEmpty {
      // Invalidate pending disk reads and suppress stale snapshots from our own RPC context.
      resetTranscriptLoading()
      loadedTranscriptPath = currentSessionPath
      loadedTranscriptKey = Self.transcriptCacheKey(at: currentSessionPath)
      if messages != source.messages { messages = source.messages }
    }
    if let remoteStats = source.stats { stats = remoteStats }
    sessionName = source.sessionName
  }

  private func loadCompleteTranscript(at path: String) {
    // get_state and get_messages normally finish almost together during startup. Both request the
    // complete JSONL transcript, so coalesce them and cache the parsed version while the file is
    // unchanged instead of parsing a large session two or three times.
    let key = Self.transcriptCacheKey(at: path)
    guard transcriptLoadInFlightKey != key, loadedTranscriptKey != key else { return }
    if let cached = TranscriptCache.shared.entries(at: path, key: key) {
      // Invalidate any older read before applying a synchronous cache hit.
      transcriptLoadGeneration += 1
      transcriptLoadInFlightKey = nil
      applyCompleteTranscript(cached, at: path, cacheKey: key)
      return
    }
    transcriptLoadGeneration += 1
    let generation = transcriptLoadGeneration
    transcriptLoadInFlightKey = key
    Task { @MainActor [weak self] in
      let (complete, finalKey) = await Task.detached(priority: .userInitiated) {
        let entries = Self.loadTranscript(at: path)
        return (entries, Self.transcriptCacheKey(at: path))
      }.value
      guard let self else { return }
      if self.transcriptLoadInFlightKey == key { self.transcriptLoadInFlightKey = nil }
      guard generation == self.transcriptLoadGeneration,
        self.currentSessionPath == path, !complete.isEmpty
      else { return }
      // Do not retain a snapshot if another process appended while it was being read.
      guard finalKey == key else {
        self.loadCompleteTranscript(at: path)
        return
      }
      self.applyCompleteTranscript(complete, at: path, cacheKey: key)
    }
  }

  nonisolated private static func transcriptCacheKey(at path: String) -> String {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
    return "\(path)\u{0}\(size)\u{0}\(modified)"
  }

  private func loadModels(startupGeneration: UUID? = nil) {
    client.request(["type": "get_available_models"]) { [weak self] result in
      guard let self,
        startupGeneration == nil || self.connectionGeneration == startupGeneration
      else { return }
      if startupGeneration != nil { self.loadSessions() }
      switch result {
      case .failure(let error):
        self.isLoadingConfiguration = false
        if startupGeneration != nil { self.connectionState = .failed("Pi 配置读取失败") }
        self.statusText = ""
        self.appendSystemError("读取模型失败：\(error.localizedDescription)")
      case .success(let response):
        guard let data = response["data"] as? PiRPCClient.JSON,
          let rawModels = data["models"] as? [PiRPCClient.JSON]
        else {
          self.isLoadingConfiguration = false
          self.statusText = ""
          self.appendSystemError("Pi 返回的模型数据格式不正确")
          return
        }
        self.allModels = rawModels.compactMap { raw in
          guard let provider = raw["provider"] as? String,
            let id = raw["id"] as? String
          else { return nil }
          let reasoning = raw["reasoning"] as? Bool ?? false
          let levelMap = raw["thinkingLevelMap"] as? PiRPCClient.JSON
          let levels = PiModel.thinkingLevelOrder.filter { level in
            if level == "xhigh" || level == "max" {
              return levelMap?[level] != nil && !(levelMap?[level] is NSNull)
            }
            return reasoning && !(levelMap?[level] is NSNull)
          }
          return PiModel(
            provider: provider,
            modelId: id,
            name: raw["name"] as? String ?? id,
            reasoning: reasoning,
            api: raw["api"] as? String,
            thinkingLevels: reasoning ? levels : ["off"]
          )
        }
        self.applyModelPreferences()
        let unmatched = PiSettingsStore.loadModelPreferences().unmatchedPatterns(in: self.allModels)
        if !unmatched.isEmpty {
          self.appendSystemError(
            "以下 enabledModels 配置未匹配可用模型：\(unmatched.joined(separator: "、"))。请检查登录状态或在模型设置中更新；不会自动删除配置。"
          )
        }
        self.isLoadingConfiguration = false
        if startupGeneration != nil { self.connectionState = .connected }
        self.statusText = ""
        if self.allModels.isEmpty {
          self.appendSystemError("Pi 没有可用模型，请先检查 ~/.pi/agent 的登录配置")
        }
      }
    }
  }

  private func loadThinkingLevels() {
    // Session switches can change the model, so no previously selected ID is authoritative here.
    synchronizeThinkingConfiguration(expectedModelID: nil)
  }

  private func synchronizeThinkingConfiguration(expectedModelID: String?) {
    thinkingConfigurationGeneration += 1
    let generation = thinkingConfigurationGeneration
    client.request(["type": "get_state"]) { [weak self] stateResult in
      guard let self, generation == self.thinkingConfigurationGeneration else { return }
      guard case .success(let stateResponse) = stateResult,
        let state = stateResponse["data"] as? PiRPCClient.JSON
      else {
        if case .failure(let error) = stateResult {
          self.appendSystemError("读取思考等级失败：\(error.localizedDescription)")
        }
        return
      }
      if let model = state["model"] as? PiRPCClient.JSON,
        let provider = model["provider"] as? String,
        let modelID = model["id"] as? String
      {
        let actualID = "\(provider)/\(modelID)"
        guard expectedModelID == nil || expectedModelID == actualID else { return }
        self.selectedModelId = actualID
      }
      self.selectedThinkingLevel = state["thinkingLevel"] as? String ?? "off"

      self.client.request(["type": "get_available_thinking_levels"]) { [weak self] result in
        guard let self, generation == self.thinkingConfigurationGeneration else { return }
        switch result {
        case .failure(let error):
          self.appendSystemError("读取推理强度失败：\(error.localizedDescription)")
        case .success(let response):
          guard let data = response["data"] as? PiRPCClient.JSON,
            let levels = data["levels"] as? [String], !levels.isEmpty
          else {
            self.appendSystemError("Pi 返回的推理强度数据格式不正确")
            return
          }
          self.thinkingLevels = levels
          if !levels.contains(self.selectedThinkingLevel) {
            self.selectedThinkingLevel = levels.first ?? "off"
          }
        }
      }
    }
  }

  func refreshModelPreferences() {
    applyModelPreferences()
  }

  private func applyModelPreferences() {
    let preferences = PiSettingsStore.loadModelPreferences()
    modelDefaultThinkingLevels = preferences.thinkingLevels
    globalDefaultThinkingLevel = preferences.defaultThinkingLevel
    compactionModelID = PiSettingsStore.compactionModelID()
    defaultModelID = UserDefaults.standard.string(forKey: Self.defaultModelKey)
    models = allModels.filter(preferences.includes)
  }

  private func loadStats() {
    client.request(["type": "get_session_stats"]) { [weak self] result in
      guard case .success(let response) = result,
        let data = response["data"] as? PiRPCClient.JSON
      else { return }
      let tokens = data["tokens"] as? PiRPCClient.JSON
      let context = data["contextUsage"] as? PiRPCClient.JSON
      self?.stats = SessionStats(
        cost: data["cost"] as? Double ?? 0,
        contextPercent: context?["percent"] as? Double,
        totalTokens: tokens?["total"] as? Int ?? 0,
        inputTokens: tokens?["input"] as? Int ?? 0,
        cacheReadTokens: tokens?["cacheRead"] as? Int ?? 0,
        cacheWriteTokens: tokens?["cacheWrite"] as? Int ?? 0
      )
    }
  }

  private func scheduleStreamingStatsRefresh() {
    guard !statsRefreshScheduled else { return }
    statsRefreshScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      guard let self else { return }
      self.statsRefreshScheduled = false
      guard self.isStreaming else { return }
      self.loadStats()
    }
  }

  func refreshSessionMetadata() {
    loadState()
    loadSessions()
  }

  private func loadSessions() {
    guard let projectURL else { return }
    let projectPath = projectURL.standardizedFileURL.path
    let generation = UUID()
    sessionLoadGeneration = generation
    Task { [weak self] in
      let items = await Task.detached(priority: .utility) {
        Self.discoverSessions(for: projectPath)
      }.value
      guard let self,
        self.projectURL?.standardizedFileURL.path == projectPath,
        self.sessionLoadGeneration == generation
      else { return }
      self.sessions = items
    }
  }

  /// Pi stores sessions in a directory derived from the working directory. Limit normal
  /// discovery to that directory; custom roots (used by imported/test sessions) still scan all.
  nonisolated static func sessionSearchRoot(for projectPath: String, root: URL) -> URL {
    let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    guard root.standardizedFileURL == defaultRoot.standardizedFileURL else { return root }
    let path = URL(fileURLWithPath: projectPath).standardizedFileURL.path
    let name =
      "--"
      + path.dropFirst().replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-") + "--"
    return root.appendingPathComponent(name, isDirectory: true)
  }

  nonisolated static func discoverSessions(
    for projectPath: String,
    root: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
  ) -> [SessionItem] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: sessionSearchRoot(for: projectPath, root: root),
        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    var result: [SessionItem] = []
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      let item = SessionDiscoveryCache.shared.item(at: url, project: projectPath) {
        guard let preview = sessionPreview(inFile: url, projectPath: projectPath) else {
          return nil
        }
        let header = preview.header
        var title = (header["name"] as? String) ?? (header["sessionName"] as? String) ?? ""
        if title.isEmpty { title = preview.text }
        if title.isEmpty { title = "未命名会话" }
        // Only user messages affect ordering, not tool output or opening a session.
        return SessionItem(
          path: url.path, title: String(title.prefix(70)),
          modifiedAt: latestUserMessageDate(inFile: url) ?? recordDate(header) ?? .distantPast)
      }
      if let item { result.append(item) }
    }
    return result.sorted { $0.modifiedAt > $1.modifiedAt }
  }

  nonisolated static func sessionExists(
    at path: String, for projectPath: String,
    root: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
  ) -> Bool {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard url.path.hasPrefix(root.standardizedFileURL.path + "/"),
      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    else { return false }
    return sessionPreview(inFile: url, projectPath: projectPath) != nil
  }

  /// Read complete JSONL records: image attachments and UTF-8 characters can cross chunk boundaries.
  /// Stop after the first user message; header-only drafts stay hidden.
  nonisolated private static func sessionPreview(
    inFile url: URL, projectPath: String
  ) -> (header: PiRPCClient.JSON, text: String)? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var header: PiRPCClient.JSON?
    var pending = Data()
    while true {
      let chunk: Data
      do {
        chunk = try handle.read(upToCount: 262_144) ?? Data()
      } catch {
        return nil
      }
      let atEnd = chunk.isEmpty
      var start = chunk.startIndex
      while start < chunk.endIndex || (atEnd && !pending.isEmpty) {
        let newline = chunk[start...].firstIndex(of: 0x0A)
        let end = newline ?? chunk.endIndex
        pending.append(contentsOf: chunk[start..<end])
        start = newline.map { $0 + 1 } ?? chunk.endIndex
        if newline == nil && !atEnd { break }
        let line = pending
        pending = Data()
        if line.isEmpty { continue }
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? PiRPCClient.JSON
        else {
          if header == nil { return nil }
          continue
        }
        if header == nil {
          guard entry["type"] as? String == "session",
            (entry["cwd"] as? String).map({ URL(fileURLWithPath: $0).standardizedFileURL.path })
              == projectPath
          else { return nil }
          header = entry
        } else if entry["type"] as? String == "message",
          let message = entry["message"] as? PiRPCClient.JSON,
          message["role"] as? String == "user", let header
        {
          return (
            header,
            contentText(message["content"])
              .trimmingCharacters(in: .whitespacesAndNewlines)
              .replacingOccurrences(of: "\n", with: " ")
          )
        }
      }
      if atEnd { break }
    }
    return nil
  }

  nonisolated static func mostRecentConversationSession(
    for projectPath: String, since cutoff: Date, now: Date,
    archivedPaths: Set<String> = [],
    root: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
  ) -> String? {
    guard
      let enumerator = FileManager.default.enumerator(
        at: sessionSearchRoot(for: projectPath, root: root),
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles])
    else { return nil }
    var newest: (path: String, date: Date)?
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      guard !archivedPaths.contains(url.path),
        let values = try? url.resourceValues(forKeys: [
          .contentModificationDateKey, .isRegularFileKey,
        ]),
        values.isRegularFile == true,
        let modified = values.contentModificationDate, modified >= cutoff,
        sessionPreview(inFile: url, projectPath: projectPath) != nil,
        let date = latestMessageDate(inFile: url, includeAssistant: true),
        date >= cutoff, date <= now
      else { continue }
      if newest == nil || date > newest!.date { newest = (url.path, date) }
    }
    return newest?.path
  }

  nonisolated private static func latestMessageDate(
    in lines: [Substring], includeAssistant: Bool
  ) -> Date? {
    for line in lines.reversed() {
      guard let data = String(line).data(using: .utf8),
        let record = try? JSONSerialization.jsonObject(with: data) as? PiRPCClient.JSON,
        record["type"] as? String == "message",
        let message = record["message"] as? PiRPCClient.JSON,
        let role = message["role"] as? String,
        role == "user"
          || (includeAssistant && role == "assistant"
            && !contentText(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
              .isEmpty)
      else { continue }
      if let date = recordDate(record) { return date }
    }
    return nil
  }

  /// 从文件尾部反向分块查找，避免为确定会话顺序而把可能很大的 JSONL 全部载入内存。
  /// 跨分块的超长消息行会保留到下一轮，因此最后一条用户消息不会因大段工具输出而遗漏。
  nonisolated static func latestUserMessageDate(inFile url: URL) -> Date? {
    latestMessageDate(inFile: url, includeAssistant: false)
  }

  nonisolated static func latestConversationMessageDate(inFile url: URL) -> Date? {
    latestMessageDate(inFile: url, includeAssistant: true)
  }

  nonisolated private static func latestMessageDate(inFile url: URL, includeAssistant: Bool)
    -> Date?
  {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }

    // Most sessions have a recent user message near the tail. Avoid decoding a full
    // megabyte (often containing tool output) just to find its timestamp.
    let chunkSize: UInt64 = 65_536
    var end = size
    var suffix = Data()
    while end > 0 {
      let start = end > chunkSize ? end - chunkSize : 0
      try? handle.seek(toOffset: start)
      guard let chunk = try? handle.read(upToCount: Int(end - start)) else { return nil }
      var combined = chunk
      combined.append(suffix)

      if start == 0 {
        let text = String(decoding: combined, as: UTF8.self)
        return latestMessageDate(
          in: text.split(separator: "\n", omittingEmptySubsequences: true),
          includeAssistant: includeAssistant)
      }

      guard let firstNewline = combined.firstIndex(of: 0x0A) else {
        suffix = combined
        end = start
        continue
      }
      let completeLines = combined[combined.index(after: firstNewline)...]
      let text = String(decoding: completeLines, as: UTF8.self)
      if let date = latestMessageDate(
        in: text.split(separator: "\n", omittingEmptySubsequences: true),
        includeAssistant: includeAssistant)
      {
        return date
      }
      suffix = Data(combined[..<firstNewline])
      end = start
    }
    return nil
  }

  nonisolated private static func recordDate(_ record: PiRPCClient.JSON) -> Date? {
    if let timestamp = record["timestamp"] as? String {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: timestamp) { return date }
      formatter.formatOptions = [.withInternetDateTime]
      if let date = formatter.date(from: timestamp) { return date }
    }
    if let message = record["message"] as? PiRPCClient.JSON,
      let milliseconds = message["timestamp"] as? NSNumber
    {
      return Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
    }
    return nil
  }

  /// RPC 事件种类较多，这里只把会影响原生界面的状态集中映射，避免视图层理解协议细节。
  private func handle(_ event: PiRPCClient.JSON) {
    guard let type = event["type"] as? String else { return }
    var activity = streamActivity
    activity.consume(event)
    if activity != streamActivity { streamActivity = activity }
    if type == "agent_start" { outputSpeedTracker.reset() }
    let now = ProcessInfo.processInfo.systemUptime
    outputSpeedTracker.consume(event, now: now)
    if type != "message_update" || now - lastOutputSpeedPublish >= 0.2 {
      let speed = outputSpeedTracker.tokensPerSecond.map { ($0 * 10).rounded() / 10 }
      if outputTokensPerSecond != speed {
        outputTokensPerSecond = speed
        lastOutputSpeedPublish = now
      }
    }
    switch type {
    case "agent_start":
      awaitingAgentStart = false
      isStreaming = true
      scheduleCodexAccountRotation()
      // 全新会话的 JSONL 路径通常在第一次请求开始时才创建。
      // 立即同步状态，确保工作区能把这个 RPC 进程与历史会话稳定关联。
      refreshSessionMetadata()
    case "agent_end":
      onTelegramLifecycleEvent?("agent_end willRetry=\(event["willRetry"] as? Bool == true)")
      if event["willRetry"] as? Bool != true { flushPendingAssistantError() }
    case "agent_settled":
      onTelegramLifecycleEvent?("agent_settled")
      flushPendingMessageDeltas()
      flushConsumedPromptsIntoTranscript()
      flushPendingAssistantError()
      // `abort` settles the old provider run, not the logical task being handed off.
      if !codexRotationInFlight { isStreaming = false }
      activeAssistantId = nil
      activeThinkingId = nil
      if !codexRotationInFlight { statusText = "" }
      loadStats()
      refreshSessionMetadata()
    case "thinking_level_changed":
      if let level = event["level"] as? String { selectedThinkingLevel = level }
    case "queue_update":
      let steering = event["steering"] as? [String] ?? []
      let followUp = event["followUp"] as? [String] ?? []
      queueSnapshotGeneration += 1
      latestQueueSnapshot = (steering, followUp)
      if !isRewritingQueue { reconcileQueue(steering: steering, followUp: followUp) }
    case "message_update":
      handleMessageUpdate(event)
      // RPC exposes cumulative provider usage on streaming events. Throttle authoritative
      // stats requests so the context footer follows the stream without one request per token.
      scheduleStreamingStatsRefresh()
    case "message_end":
      if let message = event["message"] as? PiRPCClient.JSON,
        message["role"] as? String == "assistant"
      {
        onTelegramLifecycleEvent?(
          "message_end model=\(message["provider"] as? String ?? "unknown")/\(message["model"] as? String ?? "unknown") stop=\(message["stopReason"] as? String ?? "unknown")"
        )
      }
      handleMessageEnd(event)
    case "tool_execution_start", "tool_execution_update", "tool_execution_end":
      handleToolEvent(event, type: type)
    case "compaction_start":
      handleCompactionStart(event)
    case "compaction_end":
      handleCompactionEnd(event)
    case "auto_retry_start":
      statusText = "请求失败，Pi 正在自动重试…"
    case "auto_retry_end":
      // Intermediate provider failures are part of one retry cycle, not separate chat
      // errors. Only expose the final failure if Pi exhausts all attempts.
      if event["success"] as? Bool == true {
        pendingAssistantError = nil
      } else if pendingAssistantError != nil {
        pendingAssistantError = event["finalError"] as? String ?? pendingAssistantError
        flushPendingAssistantError()
      }
      if statusText == "请求失败，Pi 正在自动重试…" { statusText = "" }
    case "extension_error":
      appendSystemError(event["error"] as? String ?? "扩展执行失败")
    case "extension_ui_request":
      if event["method"] as? String == "setStatus", event["statusKey"] as? String == "pimac-fast",
        let status = event["statusText"] as? String, ["on", "off"].contains(status)
      {
        fastModeAvailable = true
        fastModeEnabled = status == "on"
        UserDefaults.standard.set(fastModeEnabled, forKey: modelPreferenceKey + ".fastMode")
      } else {
        extensionUI?.handle(event, from: self)
      }
    default:
      break
    }
  }

  private func reconcileQueue(steering: [String], followUp: [String]) {
    var remainingSteering = steering
    var remainingFollowUp = followUp
    var pending: [QueuedPrompt] = []

    for prompt in queuedPrompts {
      guard !prompt.waitsForCompaction else {
        pending.append(prompt)
        continue
      }

      var values = prompt.delivery == .steer ? remainingSteering : remainingFollowUp
      if submittingQueuedPrompts[prompt.id] != nil {
        // queue_update can arrive before the prompt request's response. The snapshot may
        // already contain this local prompt, so claim its remote entry now; otherwise it
        // would be added below as a second prompt and later mistaken for a consumed one.
        if let index = values.firstIndex(of: prompt.rpcText) {
          values.remove(at: index)
          if prompt.delivery == .steer {
            remainingSteering = values
          } else {
            remainingFollowUp = values
          }
        }
        pending.append(prompt)
        continue
      }
      if let index = values.firstIndex(of: prompt.rpcText) {
        values.remove(at: index)
        if prompt.delivery == .steer {
          remainingSteering = values
        } else {
          remainingFollowUp = values
        }
        pending.append(prompt)
      } else {
        // queue_update means Pi has now consumed the prompt. Keep the current assistant
        // turn visually intact and add the user row when the resulting output begins.
        consumedPromptsAwaitingDisplay.append(prompt)
      }
    }

    // Usually all queued messages originate in this window. Keeping protocol-side
    // messages visible also handles queues created by an extension or another RPC action.
    pending.append(
      contentsOf: remainingSteering.map {
        QueuedPrompt(id: UUID(), text: $0, rpcText: $0, delivery: .steer, attachments: [])
      }
    )
    pending.append(
      contentsOf: remainingFollowUp.map {
        QueuedPrompt(id: UUID(), text: $0, rpcText: $0, delivery: .followUp, attachments: [])
      }
    )
    queuedPrompts = pending
  }

  private func flushConsumedPromptsIntoTranscript() {
    guard !consumedPromptsAwaitingDisplay.isEmpty else { return }
    for prompt in consumedPromptsAwaitingDisplay {
      messages.append(
        ChatEntry(
          id: UUID().uuidString,
          kind: .user,
          title: "你",
          text: prompt.text,
          attachments: prompt.attachments
        ))
    }
    consumedPromptsAwaitingDisplay.removeAll()
  }

  private func handleCompactionStart(_ event: PiRPCClient.JSON) {
    isCompacting = true
    statusText = "正在压缩上下文…"
    let id = UUID().uuidString
    activeCompactionId = id
    let model =
      compactionModelID.flatMap { configuredID in
        allModels.first { $0.id == configuredID }
      } ?? selectedModel
    let reason = Self.compactionReasonLabel(event["reason"] as? String)
    messages.append(
      ChatEntry(
        id: id,
        kind: .compaction,
        title: "上下文压缩",
        text: "正在压缩（\(reason)）…",
        isRunning: true,
        modelProvider: model?.provider,
        modelID: model?.modelId
      ))
  }

  private func handleCompactionEnd(_ event: PiRPCClient.JSON) {
    isCompacting = false
    statusText = ""
    let result = event["result"] as? PiRPCClient.JSON
    let details = result?["details"] as? PiRPCClient.JSON
    let summary = result?["summary"] as? String
    let aborted = event["aborted"] as? Bool ?? false
    let error = event["errorMessage"] as? String
    let reason = Self.compactionReasonLabel(event["reason"] as? String)
    let text: String
    if aborted {
      text = "压缩已取消（\(reason)）"
    } else if let error {
      text = "压缩失败（\(reason)）：\(error)"
    } else {
      text = summary ?? "压缩完成（\(reason)）"
    }

    if let id = activeCompactionId,
      let index = messages.firstIndex(where: { $0.id == id })
    {
      messages[index].text = text
      messages[index].isRunning = false
      messages[index].isError = error != nil
      messages[index].modelProvider =
        details?["compactionProvider"] as? String ?? messages[index].modelProvider
      messages[index].modelID =
        details?["compactionModelId"] as? String ?? messages[index].modelID
    }
    activeCompactionId = nil
    loadStats()
    refreshSessionMetadata()
    flushCompactionQueue(willRetry: event["willRetry"] as? Bool ?? false)
  }

  nonisolated private static func compactionReasonLabel(_ reason: String?) -> String {
    switch reason {
    case "manual": "手动"
    case "threshold": "达到阈值"
    case "overflow": "上下文溢出"
    default: reason ?? "未知原因"
    }
  }

  private func handleMessageUpdate(_ event: PiRPCClient.JSON) {
    guard let deltaEvent = event["assistantMessageEvent"] as? PiRPCClient.JSON,
      let type = deltaEvent["type"] as? String
    else { return }
    flushConsumedPromptsIntoTranscript()
    if type == "text_delta", let delta = deltaEvent["delta"] as? String {
      let id = activeAssistantId ?? UUID().uuidString
      if activeAssistantId == nil {
        activeAssistantId = id
        messages.append(
          ChatEntry(
            id: id,
            kind: .assistant,
            title: "Pi",
            text: "",
            isRunning: true,
            modelProvider: selectedModel?.provider,
            modelID: selectedModel?.modelId
          ))
      }
      enqueueMessageDelta(delta, for: id)
    } else if type == "thinking_delta", let delta = deltaEvent["delta"] as? String {
      let id = activeThinkingId ?? UUID().uuidString
      if activeThinkingId == nil {
        activeThinkingId = id
        messages.append(
          ChatEntry(id: id, kind: .thinking, title: "思考过程", text: "", isRunning: true))
      }
      enqueueMessageDelta(delta, for: id)
    }
  }

  private func handleMessageEnd(_ event: PiRPCClient.JSON) {
    flushPendingMessageDeltas()
    guard let message = event["message"] as? PiRPCClient.JSON else { return }
    if message["role"] as? String == "toolResult",
      let id = message["toolCallId"] as? String,
      let index = messages.firstIndex(where: { $0.id == id }), message["nestedCalls"] != nil
    {
      messages[index].nestedCalls = NestedToolCall.from(message["nestedCalls"])
      messages[index].nestedCallsComplete =
        (message["nestedCalls"] as? PiRPCClient.JSON)?["complete"] as? Bool ?? true
      return
    }
    guard message["role"] as? String == "assistant" else { return }
    let exactText = Self.contentText(message["content"])
    let errorText = Self.assistantErrorText(message)
    if activeAssistantId == nil, activeThinkingId == nil,
      !exactText.isEmpty || errorText != nil
    {
      flushConsumedPromptsIntoTranscript()
    }
    let provider = message["provider"] as? String
    let modelID = message["model"] as? String
    if let id = activeAssistantId, let index = messages.firstIndex(where: { $0.id == id }) {
      if !exactText.isEmpty { messages[index].text = exactText }
      messages[index].isRunning = false
      messages[index].timestamp = Self.messageDate(message) ?? messages[index].timestamp
      messages[index].modelProvider = provider ?? messages[index].modelProvider
      messages[index].modelID = modelID ?? messages[index].modelID
    } else if !exactText.isEmpty {
      messages.append(
        ChatEntry(
          id: UUID().uuidString,
          kind: .assistant,
          title: "Pi",
          text: exactText,
          modelProvider: provider,
          modelID: modelID,
          timestamp: Self.messageDate(message) ?? .now
        ))
    }
    if let id = activeThinkingId, let index = messages.firstIndex(where: { $0.id == id }) {
      messages[index].isRunning = false
      messages[index].timestamp = Self.messageDate(message) ?? messages[index].timestamp
    }
    // Pi emits message_end before agent_end announces whether a transient provider
    // error will be retried. Defer the error so successful retries do not leave rows such
    // as "terminated" in the transcript.
    pendingAssistantError = errorText
    activeAssistantId = nil
    activeThinkingId = nil
  }

  func handleToolEvent(_ event: PiRPCClient.JSON, type: String) {
    if let parentID = event["parentToolCallId"] as? String,
      let id = event["toolCallId"] as? String
    {
      guard
        let index = messages.firstIndex(where: {
          $0.kind == .tool && ($0.id == parentID || $0.nestedCalls.contains { $0.id == parentID })
        })
      else { return }
      let name = event["toolName"] as? String ?? "tool"
      var calls = messages[index].nestedCalls
      let callIndex: Int
      if let existing = calls.firstIndex(where: { $0.id == id }) {
        callIndex = existing
      } else {
        guard calls.count < 256 else {
          messages[index].nestedCallsComplete = false
          return
        }
        calls.append(
          NestedToolCall(
            id: id, name: name,
            input: event["args"].flatMap { Self.toolInputText(toolName: name, args: $0) },
            status: "unfinished"))
        callIndex = calls.count - 1
      }
      if type == "tool_execution_end" {
        calls[callIndex].status = event["isError"] as? Bool == true ? "error" : "ok"
        if calls[callIndex].status == "error", let result = event["result"] as? PiRPCClient.JSON {
          calls[callIndex].error = String(Self.resultText(result, toolName: name).prefix(1000))
        }
      }
      messages[index].nestedCalls = calls
      return
    }
    // Preserve protocol order if a tool starts before the scheduled UI update for the final text.
    flushPendingMessageDeltas()
    guard let id = event["toolCallId"] as? String else { return }
    let name = event["toolName"] as? String ?? "tool"
    if type == "tool_execution_start" {
      flushConsumedPromptsIntoTranscript()
      messages.append(
        ChatEntry(
          id: id,
          kind: .tool,
          title: "工具 · \(name)",
          text: name == "codemode"
            ? Self.toolInputText(toolName: name, args: event["args"]) ?? ""
            : Self.prettyJSON(event["args"]),
          isRunning: true,
          toolName: name,
          toolInput: Self.toolInputText(toolName: name, args: event["args"])
        ))
      return
    }
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
    let resultKey = type == "tool_execution_update" ? "partialResult" : "result"
    if let result = event[resultKey] as? PiRPCClient.JSON {
      let text = Self.resultText(
        result,
        toolName: name,
        preferCompleteOutput: type == "tool_execution_end"
      )
      // bash emits an initial progress result with an empty content array. Keep the
      // command arguments visible until actual output arrives instead of replacing
      // them with the protocol envelope.
      if !text.isEmpty { messages[index].text = text }
      if type == "tool_execution_end" {
        messages[index].attachments = Self.restoreImageAttachments(from: result["content"])
      }
      if result["nestedCalls"] != nil {
        messages[index].nestedCalls = NestedToolCall.from(result["nestedCalls"])
        messages[index].nestedCallsComplete =
          (result["nestedCalls"] as? PiRPCClient.JSON)?["complete"] as? Bool ?? true
      }
      if let details = result["details"] as? PiRPCClient.JSON {
        messages[index].diff = details["diff"] as? String ?? details["patch"] as? String
      }
    }
    if type == "tool_execution_end" {
      messages[index].isRunning = false
      messages[index].isError = event["isError"] as? Bool ?? false
    }
  }

  private func enqueueMessageDelta(_ text: String, for id: String) {
    pendingMessageDeltas[id, default: ""] += text
    guard !messageDeltaFlushScheduled else { return }
    messageDeltaFlushScheduled = true
    messageDeltaFlushGeneration += 1
    let generation = messageDeltaFlushGeneration
    // Provider chunks can arrive much faster than SwiftUI can lay out Markdown. Publish at most
    // about 30 frames per second while retaining every byte and flush synchronously at boundaries.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0) { [weak self] in
      guard let self, generation == self.messageDeltaFlushGeneration else { return }
      self.messageDeltaFlushScheduled = false
      self.flushPendingMessageDeltas()
    }
  }

  private func flushPendingMessageDeltas() {
    guard !pendingMessageDeltas.isEmpty else { return }
    if messageDeltaFlushScheduled {
      messageDeltaFlushGeneration += 1
      messageDeltaFlushScheduled = false
    }
    let deltas = pendingMessageDeltas
    pendingMessageDeltas.removeAll(keepingCapacity: true)
    var updatedMessages = messages
    for (id, delta) in deltas {
      guard let index = updatedMessages.firstIndex(where: { $0.id == id }) else { continue }
      updatedMessages[index].text += delta
    }
    messages = updatedMessages
  }

  private func discardPendingMessageDeltas() {
    messageDeltaFlushGeneration += 1
    messageDeltaFlushScheduled = false
    pendingMessageDeltas.removeAll(keepingCapacity: true)
  }

  private func appendSystemError(_ text: String) {
    messages.append(
      ChatEntry(id: UUID().uuidString, kind: .system, title: "错误", text: text, isError: true))
  }

  private func flushPendingAssistantError() {
    guard let error = pendingAssistantError else { return }
    pendingAssistantError = nil
    appendSystemError(error)
  }

  /// 同时写入终端和界面日志；仅保留最近 300 行，防止长期会话无限占用内存。
  private func appendDiagnostic(_ text: String) {
    let timestamp = Date.now.formatted(date: .omitted, time: .standard)
    let line = "[\(timestamp)] \(text)"
    print("[Pi Mac] \(line)")
    var lines = diagnosticText.split(separator: "\n", omittingEmptySubsequences: false).map(
      String.init)
    lines.append(line)
    if lines.count > 300 {
      lines.removeFirst(lines.count - 300)
    }
    diagnosticText = lines.joined(separator: "\n")
  }

  nonisolated static func loadTranscript(at path: String) -> [ChatEntry] {
    guard let data = FileManager.default.contents(atPath: path),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    let records = text.split(separator: "\n").compactMap { line -> PiRPCClient.JSON? in
      guard let data = String(line).data(using: .utf8) else { return nil }
      return try? JSONSerialization.jsonObject(with: data) as? PiRPCClient.JSON
    }

    // Pi sessions are trees after edits/branching. Follow the latest leaf back to the root so
    // abandoned branches are not mixed into the visible transcript. Legacy files have no IDs.
    let indexed = Dictionary(
      uniqueKeysWithValues: records.compactMap { record -> (String, PiRPCClient.JSON)? in
        guard let id = record["id"] as? String else { return nil }
        return (id, record)
      }
    )
    let branchRecords: [PiRPCClient.JSON]
    if let leafID = records.last?["id"] as? String, !indexed.isEmpty {
      var branchIDs = Set<String>()
      var currentID: String? = leafID
      while let id = currentID, let record = indexed[id], branchIDs.insert(id).inserted {
        currentID = record["parentId"] as? String
      }
      branchRecords = records.filter { record in
        guard let id = record["id"] as? String else { return false }
        return branchIDs.contains(id)
      }
    } else {
      branchRecords = records
    }

    var entries: [ChatEntry] = []
    var messageBuffer: [PiRPCClient.JSON] = []
    var currentProvider: String?
    var currentModelID: String?

    func flushMessages() {
      entries.append(contentsOf: chatEntries(from: messageBuffer))
      messageBuffer.removeAll()
    }

    for record in branchRecords {
      switch record["type"] as? String {
      case "model_change":
        currentProvider = record["provider"] as? String
        currentModelID = record["modelId"] as? String
      case "message":
        guard var message = record["message"] as? PiRPCClient.JSON else { continue }
        if message["role"] as? String == "assistant" {
          message["provider"] = message["provider"] ?? currentProvider
          message["model"] = message["model"] ?? currentModelID
        }
        if message["timestamp"] == nil { message["timestamp"] = record["timestamp"] }
        messageBuffer.append(message)
      case "compaction":
        flushMessages()
        let details = record["details"] as? PiRPCClient.JSON
        entries.append(
          ChatEntry(
            id: record["id"] as? String ?? UUID().uuidString,
            kind: .compaction,
            title: "上下文压缩",
            text: record["summary"] as? String ?? "压缩完成",
            modelProvider: details?["compactionProvider"] as? String ?? currentProvider,
            modelID: details?["compactionModelId"] as? String ?? currentModelID,
            timestamp: recordDate(record)
          ))
      default:
        continue
      }
    }
    flushMessages()
    return entries
  }

  nonisolated static func chatEntries(
    from messages: [PiRPCClient.JSON]
  ) -> [ChatEntry] {
    var toolInputs: [String: String] = [:]
    var entries: [ChatEntry] = []
    // One reverse pass avoids scanning the rest of the transcript for every failed retry.
    var retriedBeforeNextUser = Array(repeating: false, count: messages.count)
    var laterAssistant = false
    for index in messages.indices.reversed() {
      retriedBeforeNextUser[index] = laterAssistant
      switch messages[index]["role"] as? String {
      case "user": laterAssistant = false
      case "assistant": laterAssistant = true
      default: break
      }
    }

    for (messageIndex, message) in messages.enumerated() {
      let hidesRetriedError = isAssistantError(message) && retriedBeforeNextUser[messageIndex]

      if message["role"] as? String == "assistant",
        let blocks = message["content"] as? [PiRPCClient.JSON]
      {
        for block in blocks where block["type"] as? String == "toolCall" {
          guard let id = block["id"] as? String,
            let name = block["name"] as? String,
            let input = toolInputText(toolName: name, args: block["arguments"])
          else { continue }
          toolInputs[id] = input
        }
      }

      if message["role"] as? String == "assistant",
        let blocks = message["content"] as? [PiRPCClient.JSON],
        blocks.contains(where: { $0["type"] as? String == "thinking" })
      {
        let provider = message["provider"] as? String
        let modelID = message["model"] as? String
        var currentKind: ChatEntryKind?
        var currentText = ""
        func flushBlock() {
          guard let kind = currentKind, !currentText.isEmpty else { return }
          entries.append(
            ChatEntry(
              id: UUID().uuidString, kind: kind,
              title: kind == .thinking ? "思考过程" : "Pi", text: currentText,
              modelProvider: provider, modelID: modelID,
              timestamp: messageDate(message)
            ))
        }
        for block in blocks {
          let kind: ChatEntryKind
          let text: String
          switch block["type"] as? String {
          case "thinking":
            kind = .thinking
            text = block["thinking"] as? String ?? ""
          case "text":
            kind = .assistant
            text = block["text"] as? String ?? ""
          default:
            flushBlock()
            currentKind = nil
            currentText = ""
            continue
          }
          if kind != currentKind {
            flushBlock()
            currentKind = kind
            currentText = ""
          }
          if !text.isEmpty {
            if !currentText.isEmpty { currentText += "\n" }
            currentText += text
          }
        }
        flushBlock()
        if !hidesRetriedError, let errorText = assistantErrorText(message) {
          entries.append(
            ChatEntry(
              id: UUID().uuidString, kind: .system, title: "错误",
              text: errorText, isError: true, timestamp: messageDate(message)
            ))
        }
        continue
      }

      guard var entry = chatEntry(from: message) else { continue }
      if hidesRetriedError, entry.kind == .system, entry.isError { continue }
      if entry.kind == .tool, entry.toolInput == nil {
        entry.toolInput = toolInputs[entry.id]
      }
      entries.append(entry)
      if !hidesRetriedError, message["role"] as? String == "assistant",
        entry.kind == .assistant, let errorText = assistantErrorText(message)
      {
        entries.append(
          ChatEntry(
            id: UUID().uuidString,
            kind: .system,
            title: "错误",
            text: errorText,
            isError: true,
            timestamp: messageDate(message)
          ))
      }
    }
    return entries
  }

  nonisolated private static func messageDate(_ message: PiRPCClient.JSON) -> Date? {
    recordDate(["message": message]) ?? recordDate(message)
  }

  nonisolated static func chatEntry(from message: PiRPCClient.JSON) -> ChatEntry? {
    guard let role = message["role"] as? String else { return nil }
    switch role {
    case "user":
      let content = message["content"]
      let parsed = parseUserContent(contentText(content))
      return ChatEntry(
        id: UUID().uuidString,
        kind: .user,
        title: "你",
        text: parsed.text,
        attachments: parsed.attachments + restoreImageAttachments(from: content),
        timestamp: messageDate(message)
      )
    case "assistant":
      let text = contentText(message["content"])
      if !text.isEmpty {
        return ChatEntry(
          id: UUID().uuidString,
          kind: .assistant,
          title: "Pi",
          text: text,
          modelProvider: message["provider"] as? String,
          modelID: message["model"] as? String,
          timestamp: messageDate(message)
        )
      }
      if let errorText = assistantErrorText(message) {
        return ChatEntry(
          id: UUID().uuidString,
          kind: .system,
          title: "错误",
          text: errorText,
          isError: true,
          timestamp: messageDate(message)
        )
      }
      return nil
    case "toolResult":
      return ChatEntry(
        id: message["toolCallId"] as? String ?? UUID().uuidString,
        kind: .tool,
        title: "工具 · \(message["toolName"] as? String ?? "tool")",
        text: resultText(
          message,
          toolName: message["toolName"] as? String,
          preferCompleteOutput: true
        ),
        isError: message["isError"] as? Bool ?? false,
        toolName: message["toolName"] as? String,
        nestedCalls: NestedToolCall.from(message["nestedCalls"]),
        nestedCallsComplete: (message["nestedCalls"] as? PiRPCClient.JSON)?["complete"] as? Bool
          ?? true,
        diff: (message["details"] as? PiRPCClient.JSON)?["diff"] as? String
          ?? (message["details"] as? PiRPCClient.JSON)?["patch"] as? String,
        attachments: restoreImageAttachments(from: message["content"]),
        timestamp: messageDate(message)
      )
    case "bashExecution":
      return ChatEntry(
        id: UUID().uuidString,
        kind: .tool,
        title: "命令",
        text: message["output"] as? String ?? "",
        toolName: "bash",
        toolInput: (message["command"] as? String).map { "$ \($0)" },
        timestamp: messageDate(message)
      )
    default:
      return nil
    }
  }

  nonisolated private static func isAssistantError(_ message: PiRPCClient.JSON) -> Bool {
    message["role"] as? String == "assistant" && message["stopReason"] as? String == "error"
  }

  nonisolated private static func assistantErrorText(
    _ message: PiRPCClient.JSON
  ) -> String? {
    guard message["stopReason"] as? String == "error" else { return nil }
    let detail = (message["errorMessage"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return detail?.isEmpty == false ? detail : "模型调用失败，未生成回复。"
  }

  nonisolated private static func parseUserContent(
    _ content: String
  ) -> (text: String, attachments: [PromptAttachment]) {
    let startMarker = "<pi-mac-attached-files>"
    let endMarker = "</pi-mac-attached-files>"
    guard let start = content.range(of: startMarker),
      let end = content.range(of: endMarker, range: start.upperBound..<content.endIndex)
    else { return (content, []) }

    let paths = content[start.upperBound..<end.lowerBound]
      .split(separator: "\n")
      .map(String.init)
    let attachments = paths.map { path in
      PromptAttachment(
        url: URL(fileURLWithPath: path),
        mimeType: UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?
          .preferredMIMEType
      )
    }
    var displayText = content
    displayText.removeSubrange(start.lowerBound..<end.upperBound)
    return (displayText.trimmingCharacters(in: .whitespacesAndNewlines), attachments)
  }

  nonisolated private static func contentText(_ content: Any?) -> String {
    if let text = content as? String { return text }
    guard let blocks = content as? [PiRPCClient.JSON] else { return "" }
    return blocks.compactMap { block in
      switch block["type"] as? String {
      case "text": return block["text"] as? String
      case "thinking": return nil
      default: return nil
      }
    }.joined(separator: "\n")
  }

  /// Pi 会把用户图片以 Base64 内容块保存在会话 JSONL 中。恢复会话时将内容块
  /// 落盘到稳定目录；以内容摘要命名可以让多次刷新复用同一个文件。
  nonisolated private static func restoreImageAttachments(from content: Any?) -> [PromptAttachment]
  {
    guard let blocks = content as? [PiRPCClient.JSON] else { return [] }
    let fileManager = FileManager.default
    guard
      let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { return [] }
    let directory = applicationSupport.appendingPathComponent(
      "PiMac/Attachments", isDirectory: true)

    return blocks.compactMap { block in
      guard block["type"] as? String == "image",
        let mimeType = block["mimeType"] as? String,
        mimeType.hasPrefix("image/"),
        let encoded = block["data"] as? String,
        encoded.utf8.count <= 28 * 1_024 * 1_024,
        let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
        data.count <= 20 * 1_024 * 1_024
      else { return nil }

      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      let fileExtension = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "img"
      let url = directory.appendingPathComponent("pi-session-\(digest).\(fileExtension)")
      do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
          try data.write(to: url, options: .atomic)
        }
        return PromptAttachment(url: url, mimeType: mimeType)
      } catch {
        return nil
      }
    }
  }

  nonisolated static func toolInputText(toolName: String, args: Any?) -> String? {
    // Pi exposes codemode as raw JavaScript to providers, while normal RPC tool
    // events/history use { code }. Accept both forms without re-encoding the script.
    if toolName == "codemode", let code = args as? String { return code }
    guard let args = args as? PiRPCClient.JSON else { return nil }
    switch toolName {
    case "codemode":
      return args["code"] as? String
    case "bash":
      guard let command = args["command"] as? String, !command.isEmpty else { return nil }
      return "$ \(command)"
    case "read":
      guard let path = args["path"] as? String, !path.isEmpty else { return nil }
      let offset = (args["offset"] as? NSNumber)?.intValue
      let limit = (args["limit"] as? NSNumber)?.intValue
      guard offset != nil || limit != nil else { return path }
      let firstLine = offset ?? 1
      if let limit { return "\(path):\(firstLine)-\(firstLine + max(limit - 1, 0))" }
      return "\(path):\(firstLine)"
    case "edit", "write":
      return args["path"] as? String
    case "fetch_content":
      if let url = args["url"] as? String { return url }
      if let urls = args["urls"] as? [String] { return urls.joined(separator: "\n") }
      return nil
    case "web_search":
      if let query = args["query"] as? String { return query }
      if let queries = args["queries"] as? [String] { return queries.joined(separator: " · ") }
      return nil
    case "source_check":
      return args["claim"] as? String
    case "generate_image":
      return args["prompt"] as? String
    default:
      return args["path"] as? String
    }
  }

  nonisolated private static func resultText(
    _ result: PiRPCClient.JSON,
    toolName: String? = nil,
    preferCompleteOutput: Bool = false
  ) -> String {
    let text = contentText(result["content"])

    // Pi intentionally truncates the final bash result to its context limit and
    // stores the complete output in a temporary file. Replacing the live preview
    // with that final result made long commands appear to contain only a tiny tail
    // (and a single very long line could appear to contain no output at all).
    if preferCompleteOutput, toolName == "bash",
      let details = result["details"] as? PiRPCClient.JSON,
      let truncation = details["truncation"] as? PiRPCClient.JSON,
      truncation["truncated"] as? Bool == true,
      let path = details["fullOutputPath"] as? String,
      let data = FileManager.default.contents(atPath: path), !data.isEmpty
    {
      return String(decoding: data, as: UTF8.self)
    }

    // An empty content array is a normal initial streaming update, not a useful
    // result to render. Results without a content field may still be structured
    // custom-tool values, for which the JSON fallback remains useful.
    if result["content"] != nil { return text }
    return prettyJSON(result)
  }

  nonisolated private static func prettyJSON(_ value: Any?) -> String {
    guard let value, JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  private static func suggestedPiPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
      "\(home)/Library/pnpm/bin/pi",
      "/opt/homebrew/bin/pi",
      "/usr/local/bin/pi",
    ]
    return candidates.first(where: FileManager.default.isExecutableFile(atPath:)) ?? candidates[0]
  }
}

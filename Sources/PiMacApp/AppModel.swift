import AppKit
import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
  @Published var connectionState: ConnectionState = .disconnected
  @Published var projectURL: URL?
  @Published var messages: [ChatEntry] = []
  @Published var models: [PiModel] = []
  @Published var selectedModelId = ""
  @Published var thinkingLevels = ["off"]
  @Published var selectedThinkingLevel = "off"
  @Published var isStreaming = false
  @Published var isCompacting = false
  @Published var isLoadingConfiguration = false
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

  private static let lastProjectPathKey = "lastProjectPath"

  private let client = PiRPCClient()
  private var activeAssistantId: String?
  private var activeThinkingId: String?
  private var sessionLoadGeneration = UUID()
  private var isRewritingQueue = false
  private var submittingQueuedPrompts: [UUID: Int] = [:]
  private var consumedPromptsAwaitingDisplay: [QueuedPrompt] = []
  private var pendingAssistantError: String?
  private var queueSnapshotGeneration = 0
  private var latestQueueSnapshot: (steering: [String], followUp: [String])?

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
    restoreLastProjectOnLaunch: Bool = true
  ) {
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
      self.isCompacting = false
      if case .disconnected = self.connectionState { return }
      self.connectionState = .failed("Pi 进程退出，状态码 \(code)")
    }

    Task { @MainActor [weak self] in
      await Task.yield()
      if let startupProjectURL {
        if let startupSessionPath {
          // 本地 JSONL 读取与 RPC 进程启动并行进行，历史内容无需等待 Pi 完成连接。
          let transcriptTask = Task.detached(priority: .userInitiated) {
            Self.loadTranscript(at: startupSessionPath)
          }
          self?.connect(
            to: startupProjectURL,
            continueLastSession: continueLastSession,
            sessionPath: startupSessionPath
          )
          let cachedMessages = await transcriptTask.value
          if self?.messages.isEmpty == true { self?.messages = cachedMessages }
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

    connectionState = .connecting
    if !preservingState {
      messages.removeAll()
      queuedPrompts.removeAll()
      submittingQueuedPrompts.removeAll()
      consumedPromptsAwaitingDisplay.removeAll()
      pendingAssistantError = nil
      queueSnapshotGeneration = 0
      latestQueueSnapshot = nil
      diagnosticText = ""
    }
    self.projectURL = projectURL
    do {
      try client.start(
        piPath: piPath,
        workingDirectory: projectURL,
        continueLastSession: continueLastSession
      )
      UserDefaults.standard.set(projectURL.path, forKey: Self.lastProjectPathKey)
      connectionState = .connected
      isLoadingConfiguration = true
      statusText = sessionPath == nil ? "正在读取 Pi 配置…" : "正在打开会话…"
      if let sessionPath {
        client.request(["type": "switch_session", "sessionPath": sessionPath]) {
          [weak self] result in
          guard let self else { return }
          switch result {
          case .failure(let error):
            self.appendSystemError(error.localizedDescription)
            self.refreshAll()
          case .success(let response):
            let cancelled = (response["data"] as? PiRPCClient.JSON)?["cancelled"] as? Bool ?? false
            if !cancelled { self.refreshAll() }
          }
        }
      } else {
        refreshAll()
      }
      startConfigurationTimeout()
    } catch {
      connectionState = .failed(error.localizedDescription)
    }
  }

  var isProcessRunning: Bool { client.isRunning }
  var isBusy: Bool { isStreaming || isCompacting }

  var hasUnsubmittedInput: Bool {
    !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
  }

  /// Stop an idle RPC process without discarding the session's transcript, composer draft,
  /// attachments, or extension snapshot. Selecting the session starts a replacement process.
  func suspendProcess() {
    guard !isBusy, queuedPrompts.isEmpty, client.isRunning else { return }
    connectionState = .disconnected
    isLoadingConfiguration = false
    statusText = ""
    client.stop()
  }

  func resumeProcess(sessionPath: String?, continueLastSession: Bool) {
    guard !client.isRunning, let projectURL else { return }
    let targetPath = sessionPath ?? (currentSessionPath.isEmpty ? nil : currentSessionPath)
    connect(
      to: projectURL,
      continueLastSession: targetPath == nil ? continueLastSession : false,
      sessionPath: targetPath,
      preservingState: true
    )
  }

  func disconnect() {
    extensionUI?.removeRequests(from: self)
    connectionState = .disconnected
    isStreaming = false
    isCompacting = false
    isLoadingConfiguration = false
    queuedPrompts = []
    submittingQueuedPrompts.removeAll()
    consumedPromptsAwaitingDisplay.removeAll()
    pendingAssistantError = nil
    queueSnapshotGeneration = 0
    latestQueueSnapshot = nil
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
    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !attachments.isEmpty, client.isRunning else { return }
    let sentAttachments = attachments
    composerText = ""
    attachments = []
    let displayText = text.isEmpty ? "请查看附件。" : text
    let rpcText = Self.rpcText(for: displayText, attachments: sentAttachments)

    if isCompacting {
      queuedPrompts.append(
        QueuedPrompt(
          id: UUID(),
          text: displayText,
          rpcText: rpcText,
          delivery: delivery,
          attachments: sentAttachments,
          waitsForCompaction: true
        ))
      return
    }

    if isStreaming {
      submitQueuedPrompt(
        QueuedPrompt(
          id: UUID(),
          text: displayText,
          rpcText: rpcText,
          delivery: delivery,
          attachments: sentAttachments
        ))
      return
    }

    submitImmediatePrompt(
      QueuedPrompt(
        id: UUID(),
        text: displayText,
        rpcText: rpcText,
        delivery: delivery,
        attachments: sentAttachments
      ))
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

  private func dequeuePrompt(
    id: UUID, onRemoved: ((QueuedPrompt) -> Void)? = nil
  ) {
    guard let target = queuedPrompts.first(where: { $0.id == id }),
      !isRewritingQueue, submittingQueuedPrompts[id] == nil
    else { return }
    if target.waitsForCompaction {
      queuedPrompts.removeAll { $0.id == id }
      onRemoved?(target)
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
        if prompt.id == target.id {
          removedTarget = prompt
        } else {
          stillQueued.append(prompt)
        }
      }

      self.queuedPrompts = stillQueued
      if let removedTarget { onRemoved?(removedTarget) }
      let remotePrompts = stillQueued.filter { !$0.waitsForCompaction }
      guard !remotePrompts.isEmpty else {
        self.isRewritingQueue = false
        self.latestQueueSnapshot = (steering, followUp)
        return
      }

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

  private func submitImmediatePrompt(
    _ prompt: QueuedPrompt,
    completion: ((Bool) -> Void)? = nil
  ) {
    messages.append(
      ChatEntry(
        id: UUID().uuidString,
        kind: .user,
        title: "你",
        text: prompt.text,
        attachments: prompt.attachments
      ))
    client.request(Self.promptCommand(message: prompt.rpcText, attachments: prompt.attachments)) {
      [weak self] result in
      switch result {
      case .success:
        completion?(true)
      case .failure(let error):
        self?.appendSystemError(error.localizedDescription)
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
    sendQueuedPrompt(submitted) { [weak self] result in
      guard let self else { return }
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
    client.request(command, completion: completion)
  }

  private func flushCompactionQueue(willRetry: Bool) {
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

  nonisolated private static func rpcText(
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

  func newSession() {
    client.request(["type": "new_session"]) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error): self.appendSystemError(error.localizedDescription)
      case .success(let response):
        let cancelled = (response["data"] as? PiRPCClient.JSON)?["cancelled"] as? Bool ?? false
        if !cancelled {
          self.messages.removeAll()
          self.queuedPrompts.removeAll()
          self.submittingQueuedPrompts.removeAll()
          self.consumedPromptsAwaitingDisplay.removeAll()
          self.pendingAssistantError = nil
          self.queueSnapshotGeneration = 0
          self.latestQueueSnapshot = nil
          self.sessionName = ""
          self.stats = nil
          self.refreshAll()
        }
      }
    }
  }

  func switchSession(path: String) {
    guard !isBusy else {
      statusText = "当前任务进行中，暂时不能切换会话"
      return
    }
    client.request(["type": "switch_session", "sessionPath": path]) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error): self.appendSystemError(error.localizedDescription)
      case .success(let response):
        let cancelled = (response["data"] as? PiRPCClient.JSON)?["cancelled"] as? Bool ?? false
        if !cancelled { self.refreshAll() }
      }
    }
  }

  func changeModel(to id: String) {
    guard id != selectedModelId, let model = models.first(where: { $0.id == id }) else { return }
    client.request(["type": "set_model", "provider": model.provider, "modelId": model.modelId]) {
      [weak self] result in
      switch result {
      case .success:
        self?.selectedModelId = id
        self?.loadThinkingLevels()
      case .failure(let error): self?.appendSystemError(error.localizedDescription)
      }
    }
  }

  func changeThinkingLevel(to level: String) {
    guard level != selectedThinkingLevel else { return }
    client.request(["type": "set_thinking_level", "level": level]) { [weak self] result in
      switch result {
      case .success: self?.selectedThinkingLevel = level
      case .failure(let error): self?.appendSystemError(error.localizedDescription)
      }
    }
  }

  func switchCodexAccount(to accountName: String) {
    guard !isBusy else {
      statusText = "当前任务完成后才能切换 Codex 账户"
      return
    }
    runExtensionCommand(
      "/accounts switch \(accountName)",
      progress: "正在切换到 \(accountName)…"
    )
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
    client.request(["type": "prompt", "message": message]) { [weak self] result in
      self?.statusText = ""
      if case .failure(let error) = result {
        self?.appendSystemError(error.localizedDescription)
      }
    }
  }

  func compact() {
    guard !isBusy else { return }
    isCompacting = true
    statusText = "正在压缩上下文…"
    client.request(["type": "compact"]) { [weak self] result in
      guard let self else { return }
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
      ChatEntry(id: UUID().uuidString, kind: .system, title: "通知", text: text)
    )
  }

  private func restoreLastProject() {
    guard let path = UserDefaults.standard.string(forKey: Self.lastProjectPathKey),
      FileManager.default.fileExists(atPath: path)
    else { return }
    connect(to: URL(fileURLWithPath: path, isDirectory: true))
  }

  private func startConfigurationTimeout() {
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(15))
      guard let self, self.isLoadingConfiguration else { return }
      self.isLoadingConfiguration = false
      self.statusText = ""
      self.appendSystemError("读取 Pi 配置超过 15 秒。请展开左侧“诊断日志”查看 RPC 是否返回。")
      self.appendDiagnostic("配置读取超时：没有收到 get_available_models 的有效响应")
    }
  }

  private func refreshAll() {
    loadState()
    loadMessages()
    loadModels()
    loadThinkingLevels()
    loadStats()
    loadSessions()
  }

  private func loadState() {
    client.request(["type": "get_state"]) { [weak self] result in
      guard case .success(let response) = result,
        let data = response["data"] as? PiRPCClient.JSON
      else { return }
      self?.selectedThinkingLevel = data["thinkingLevel"] as? String ?? "off"
      self?.isStreaming = data["isStreaming"] as? Bool ?? false
      self?.isCompacting = data["isCompacting"] as? Bool ?? false
      self?.sessionName = data["sessionName"] as? String ?? ""
      self?.currentSessionPath = data["sessionFile"] as? String ?? ""
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
      guard case .success(let response) = result,
        let data = response["data"] as? PiRPCClient.JSON,
        let rawMessages = data["messages"] as? [PiRPCClient.JSON]
      else { return }
      self?.messages = Self.chatEntries(from: rawMessages)
    }
  }

  private func loadModels() {
    client.request(["type": "get_available_models"]) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        self.isLoadingConfiguration = false
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
        self.models = rawModels.compactMap { raw in
          guard let provider = raw["provider"] as? String,
            let id = raw["id"] as? String
          else { return nil }
          return PiModel(provider: provider, modelId: id, name: raw["name"] as? String ?? id)
        }
        self.isLoadingConfiguration = false
        self.statusText = ""
        if self.models.isEmpty {
          self.appendSystemError("Pi 没有可用模型，请先检查 ~/.pi/agent 的登录配置")
        }
      }
    }
  }

  private func loadThinkingLevels() {
    client.request(["type": "get_available_thinking_levels"]) { [weak self] result in
      guard let self else { return }
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
      }
    }
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
        totalTokens: tokens?["total"] as? Int ?? 0
      )
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

  nonisolated static func discoverSessions(for projectPath: String) -> [SessionItem] {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    var result: [SessionItem] = []
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
      let data = try? handle.read(upToCount: 262_144)
      try? handle.close()
      guard let data, let text = String(data: data, encoding: .utf8) else { continue }

      let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
      guard let first = lines.first,
        let headerData = String(first).data(using: .utf8),
        let header = try? JSONSerialization.jsonObject(with: headerData) as? PiRPCClient.JSON,
        header["type"] as? String == "session",
        (header["cwd"] as? String).map({ URL(fileURLWithPath: $0).standardizedFileURL.path })
          == projectPath
      else { continue }

      var title = (header["name"] as? String) ?? (header["sessionName"] as? String) ?? ""
      var firstUserText: String?
      for line in lines.dropFirst() {
        guard let lineData = String(line).data(using: .utf8),
          let entry = try? JSONSerialization.jsonObject(with: lineData) as? PiRPCClient.JSON,
          entry["type"] as? String == "message",
          let message = entry["message"] as? PiRPCClient.JSON,
          message["role"] as? String == "user"
        else { continue }
        firstUserText = contentText(message["content"])
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .replacingOccurrences(of: "\n", with: " ")
        break
      }
      // 启动新任务时 Pi 可能立即写入会话头和配置记录。没有用户消息的文件
      // 仍然只是草稿，不应进入会话列表。
      guard let firstUserText else { continue }
      if title.isEmpty { title = firstUserText }
      if title.isEmpty { title = "未命名会话" }
      title = String(title.prefix(70))
      // Pi may touch a session file while merely opening it. Sort by the latest
      // actual message instead of filesystem modification time so viewing a
      // session does not move it to the top of the list.
      let activityDates = [
        latestMessageDate(in: lines),
        latestMessageDate(inTailOf: url),
        recordDate(header),
      ].compactMap { $0 }
      result.append(
        SessionItem(
          path: url.path,
          title: title,
          modifiedAt: activityDates.max() ?? .distantPast
        ))
    }
    return result.sorted { $0.modifiedAt > $1.modifiedAt }
  }

  nonisolated private static func latestMessageDate(in lines: [Substring]) -> Date? {
    for line in lines.reversed() {
      guard let data = String(line).data(using: .utf8),
        let record = try? JSONSerialization.jsonObject(with: data) as? PiRPCClient.JSON,
        record["type"] as? String == "message"
      else { continue }
      if let date = recordDate(record) { return date }
    }
    return nil
  }

  nonisolated private static func latestMessageDate(inTailOf url: URL) -> Date? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let tailSize: UInt64 = 1_048_576
    try? handle.seek(toOffset: size > tailSize ? size - tailSize : 0)
    guard let data = try? handle.readToEnd(),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    return latestMessageDate(in: text.split(separator: "\n", omittingEmptySubsequences: true))
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
    switch type {
    case "agent_start":
      isStreaming = true
      // 全新会话的 JSONL 路径通常在第一次请求开始时才创建。
      // 立即同步状态，确保工作区能把这个 RPC 进程与历史会话稳定关联。
      refreshSessionMetadata()
    case "agent_end":
      if event["willRetry"] as? Bool != true { flushPendingAssistantError() }
    case "agent_settled":
      flushConsumedPromptsIntoTranscript()
      flushPendingAssistantError()
      isStreaming = false
      activeAssistantId = nil
      activeThinkingId = nil
      statusText = ""
      loadStats()
      refreshSessionMetadata()
    case "queue_update":
      let steering = event["steering"] as? [String] ?? []
      let followUp = event["followUp"] as? [String] ?? []
      queueSnapshotGeneration += 1
      latestQueueSnapshot = (steering, followUp)
      if !isRewritingQueue { reconcileQueue(steering: steering, followUp: followUp) }
    case "message_update":
      handleMessageUpdate(event)
    case "message_end":
      handleMessageEnd(event)
    case "tool_execution_start", "tool_execution_update", "tool_execution_end":
      handleToolEvent(event, type: type)
    case "compaction_start":
      isCompacting = true
      statusText = "正在压缩上下文…"
    case "compaction_end":
      isCompacting = false
      statusText = ""
      loadStats()
      refreshSessionMetadata()
      flushCompactionQueue(willRetry: event["willRetry"] as? Bool ?? false)
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
      extensionUI?.handle(event, from: self)
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

  private func handleMessageUpdate(_ event: PiRPCClient.JSON) {
    guard let deltaEvent = event["assistantMessageEvent"] as? PiRPCClient.JSON,
      let type = deltaEvent["type"] as? String
    else { return }
    flushConsumedPromptsIntoTranscript()
    if type == "text_delta", let delta = deltaEvent["delta"] as? String {
      let id = activeAssistantId ?? UUID().uuidString
      if activeAssistantId == nil {
        activeAssistantId = id
        messages.append(ChatEntry(id: id, kind: .assistant, title: "Pi", text: "", isRunning: true))
      }
      append(delta, to: id)
    } else if type == "thinking_delta", let delta = deltaEvent["delta"] as? String {
      let id = activeThinkingId ?? UUID().uuidString
      if activeThinkingId == nil {
        activeThinkingId = id
        messages.append(
          ChatEntry(id: id, kind: .thinking, title: "思考过程", text: "", isRunning: true))
      }
      append(delta, to: id)
    }
  }

  private func handleMessageEnd(_ event: PiRPCClient.JSON) {
    guard let message = event["message"] as? PiRPCClient.JSON,
      message["role"] as? String == "assistant"
    else { return }
    let exactText = Self.contentText(message["content"])
    let errorText = Self.assistantErrorText(message)
    if activeAssistantId == nil, activeThinkingId == nil,
      !exactText.isEmpty || errorText != nil
    {
      flushConsumedPromptsIntoTranscript()
    }
    if let id = activeAssistantId, let index = messages.firstIndex(where: { $0.id == id }) {
      if !exactText.isEmpty { messages[index].text = exactText }
      messages[index].isRunning = false
    } else if !exactText.isEmpty {
      messages.append(
        ChatEntry(id: UUID().uuidString, kind: .assistant, title: "Pi", text: exactText))
    }
    if let id = activeThinkingId, let index = messages.firstIndex(where: { $0.id == id }) {
      messages[index].isRunning = false
    }
    // Pi emits message_end before agent_end announces whether a transient provider
    // error will be retried. Defer the error so successful retries do not leave rows such
    // as "terminated" in the transcript.
    pendingAssistantError = errorText
    activeAssistantId = nil
    activeThinkingId = nil
  }

  private func handleToolEvent(_ event: PiRPCClient.JSON, type: String) {
    guard let id = event["toolCallId"] as? String else { return }
    let name = event["toolName"] as? String ?? "tool"
    if type == "tool_execution_start" {
      flushConsumedPromptsIntoTranscript()
      messages.append(
        ChatEntry(
          id: id,
          kind: .tool,
          title: "工具 · \(name)",
          text: Self.prettyJSON(event["args"]),
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
      if let details = result["details"] as? PiRPCClient.JSON {
        messages[index].diff = details["diff"] as? String ?? details["patch"] as? String
      }
    }
    if type == "tool_execution_end" {
      messages[index].isRunning = false
      messages[index].isError = event["isError"] as? Bool ?? false
    }
  }

  private func append(_ text: String, to id: String) {
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[index].text += text
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

  nonisolated private static func loadTranscript(at path: String) -> [ChatEntry] {
    guard let data = FileManager.default.contents(atPath: path),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    let messages = text.split(separator: "\n").compactMap { line -> PiRPCClient.JSON? in
      guard let data = String(line).data(using: .utf8),
        let record = try? JSONSerialization.jsonObject(with: data) as? PiRPCClient.JSON,
        record["type"] as? String == "message"
      else { return nil }
      return record["message"] as? PiRPCClient.JSON
    }
    return chatEntries(from: messages)
  }

  nonisolated static func chatEntries(
    from messages: [PiRPCClient.JSON]
  ) -> [ChatEntry] {
    var toolInputs: [String: String] = [:]
    var entries: [ChatEntry] = []

    for (messageIndex, message) in messages.enumerated() {
      let hidesRetriedError =
        isAssistantError(message)
        && hasLaterAssistant(beforeNextUserAfter: messageIndex, in: messages)

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
            isError: true
          ))
      }
    }
    return entries
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
        attachments: parsed.attachments + restoreImageAttachments(from: content)
      )
    case "assistant":
      let text = contentText(message["content"])
      if !text.isEmpty {
        return ChatEntry(id: UUID().uuidString, kind: .assistant, title: "Pi", text: text)
      }
      if let errorText = assistantErrorText(message) {
        return ChatEntry(
          id: UUID().uuidString,
          kind: .system,
          title: "错误",
          text: errorText,
          isError: true
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
        diff: (message["details"] as? PiRPCClient.JSON)?["diff"] as? String
          ?? (message["details"] as? PiRPCClient.JSON)?["patch"] as? String
      )
    case "bashExecution":
      return ChatEntry(
        id: UUID().uuidString,
        kind: .tool,
        title: "命令",
        text: message["output"] as? String ?? "",
        toolName: "bash",
        toolInput: (message["command"] as? String).map { "$ \($0)" }
      )
    default:
      return nil
    }
  }

  nonisolated private static func isAssistantError(_ message: PiRPCClient.JSON) -> Bool {
    message["role"] as? String == "assistant" && message["stopReason"] as? String == "error"
  }

  nonisolated private static func hasLaterAssistant(
    beforeNextUserAfter index: Int, in messages: [PiRPCClient.JSON]
  ) -> Bool {
    guard index + 1 < messages.count else { return false }
    for message in messages[(index + 1)...] {
      switch message["role"] as? String {
      case "user": return false
      case "assistant": return true
      default: continue
      }
    }
    return false
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
    guard let args = args as? PiRPCClient.JSON else { return nil }
    switch toolName {
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

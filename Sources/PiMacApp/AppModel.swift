import AppKit
import Combine
import Foundation

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
  @Published var isLoadingConfiguration = false
  @Published var sessionName = ""
  @Published var sessions: [SessionItem] = []
  @Published var currentSessionPath = ""
  @Published var stats: SessionStats?
  @Published var composerText = ""
  @Published var extensionDialog: ExtensionDialog?
  @Published var statusText = ""
  @Published var extensionStatuses: [String: String] = [:]
  @Published var codexAccounts: [CodexAccountStatus] = []
  @Published var geminiUsage: GeminiUsageStatus?
  @Published var codexAccountsUpdatedAt: Date?
  @Published var diagnosticText = ""

  private static let lastProjectPathKey = "lastProjectPath"

  private let client = PiRPCClient()
  private var activeAssistantId: String?
  private var activeThinkingId: String?

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
    startupSessionPath: String? = nil
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
      if case .disconnected = self.connectionState { return }
      self.connectionState = .failed("Pi 进程退出，状态码 \(code)")
    }

    Task { @MainActor [weak self] in
      await Task.yield()
      if let startupProjectURL {
        self?.connect(
          to: startupProjectURL,
          continueLastSession: continueLastSession,
          sessionPath: startupSessionPath
        )
      } else {
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
    sessionPath: String?
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
    messages.removeAll()
    diagnosticText = ""
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

  func disconnect() {
    connectionState = .disconnected
    isStreaming = false
    isLoadingConfiguration = false
    sessions = []
    currentSessionPath = ""
    client.stop()
  }

  func sendPrompt() {
    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, client.isRunning else { return }
    composerText = ""
    messages.append(
      ChatEntry(
        id: UUID().uuidString,
        kind: .user,
        title: isStreaming ? "你 · 已插入" : "你",
        text: text
      ))

    var command: PiRPCClient.JSON = ["type": "prompt", "message": text]
    if isStreaming {
      command["streamingBehavior"] = "steer"
    }
    client.request(command) { [weak self] result in
      if case .failure(let error) = result {
        self?.appendSystemError(error.localizedDescription)
      }
    }
  }

  func abort() {
    client.request(["type": "clear_queue"]) { [weak self] result in
      if case .success(let response) = result,
        let data = response["data"] as? PiRPCClient.JSON
      {
        let queued =
          ((data["steering"] as? [String]) ?? []) + ((data["followUp"] as? [String]) ?? [])
        if !queued.isEmpty {
          self?.composerText = queued.joined(separator: "\n")
        }
      }
      self?.client.request(["type": "abort"])
    }
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
          self.sessionName = ""
          self.stats = nil
          self.refreshAll()
        }
      }
    }
  }

  func switchSession(path: String) {
    guard !isStreaming else {
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

  func setSessionName(_ name: String) {
    client.request(["type": "set_session_name", "name": name]) { [weak self] result in
      switch result {
      case .success: self?.loadSessions()
      case .failure(let error): self?.appendSystemError(error.localizedDescription)
      }
    }
  }

  func switchCodexAccount(to accountName: String) {
    guard !isStreaming else {
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
    statusText = "正在压缩上下文…"
    client.request(["type": "compact"]) { [weak self] result in
      self?.statusText = ""
      switch result {
      case .success: self?.loadStats()
      case .failure(let error): self?.appendSystemError(error.localizedDescription)
      }
    }
  }

  func answerDialog(value: String? = nil, confirmed: Bool? = nil, cancelled: Bool = false) {
    guard let dialog = extensionDialog else { return }
    var response: PiRPCClient.JSON = ["type": "extension_ui_response", "id": dialog.id]
    if cancelled { response["cancelled"] = true }
    if let value { response["value"] = value }
    if let confirmed { response["confirmed"] = confirmed }
    client.sendExtensionResponse(response)
    extensionDialog = nil
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
      self?.messages = rawMessages.compactMap(Self.chatEntry(from:))
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

  private func loadSessions() {
    guard let projectURL else { return }
    let projectPath = projectURL.standardizedFileURL.path
    Task { [weak self] in
      let items = await Task.detached(priority: .utility) {
        Self.discoverSessions(for: projectPath)
      }.value
      guard let self, self.projectURL?.standardizedFileURL.path == projectPath else { return }
      self.sessions = items
    }
  }

  nonisolated private static func discoverSessions(for projectPath: String) -> [SessionItem] {
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
      if title.isEmpty {
        for line in lines.dropFirst() {
          guard let lineData = String(line).data(using: .utf8),
            let entry = try? JSONSerialization.jsonObject(with: lineData) as? PiRPCClient.JSON,
            entry["type"] as? String == "message",
            let message = entry["message"] as? PiRPCClient.JSON,
            message["role"] as? String == "user"
          else { continue }
          title = contentText(message["content"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
          break
        }
      }
      if title.isEmpty { title = "未命名会话" }
      title = String(title.prefix(70))
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
      result.append(
        SessionItem(
          path: url.path,
          title: title,
          modifiedAt: values?.contentModificationDate ?? .distantPast
        ))
    }
    return result.sorted { $0.modifiedAt > $1.modifiedAt }
  }

  /// RPC 事件种类较多，这里只把会影响原生界面的状态集中映射，避免视图层理解协议细节。
  private func handle(_ event: PiRPCClient.JSON) {
    guard let type = event["type"] as? String else { return }
    switch type {
    case "agent_start":
      isStreaming = true
    case "agent_settled":
      isStreaming = false
      activeAssistantId = nil
      activeThinkingId = nil
      statusText = ""
      loadStats()
      loadSessions()
    case "message_update":
      handleMessageUpdate(event)
    case "message_end":
      handleMessageEnd(event)
    case "tool_execution_start", "tool_execution_update", "tool_execution_end":
      handleToolEvent(event, type: type)
    case "compaction_start":
      statusText = "正在压缩上下文…"
    case "auto_retry_start":
      statusText = "请求失败，Pi 正在自动重试…"
    case "extension_error":
      appendSystemError(event["error"] as? String ?? "扩展执行失败")
    case "extension_ui_request":
      handleExtensionUI(event)
    default:
      break
    }
  }

  private func handleMessageUpdate(_ event: PiRPCClient.JSON) {
    guard let deltaEvent = event["assistantMessageEvent"] as? PiRPCClient.JSON,
      let type = deltaEvent["type"] as? String
    else { return }
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
    activeAssistantId = nil
    activeThinkingId = nil
  }

  private func handleToolEvent(_ event: PiRPCClient.JSON, type: String) {
    guard let id = event["toolCallId"] as? String else { return }
    let name = event["toolName"] as? String ?? "tool"
    if type == "tool_execution_start" {
      messages.append(
        ChatEntry(
          id: id,
          kind: .tool,
          title: "工具 · \(name)",
          text: Self.prettyJSON(event["args"]),
          isRunning: true,
          toolName: name
        ))
      return
    }
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
    let resultKey = type == "tool_execution_update" ? "partialResult" : "result"
    if let result = event[resultKey] as? PiRPCClient.JSON {
      messages[index].text = Self.resultText(result)
      if let details = result["details"] as? PiRPCClient.JSON {
        messages[index].diff = details["diff"] as? String ?? details["patch"] as? String
      }
    }
    if type == "tool_execution_end" {
      messages[index].isRunning = false
      messages[index].isError = event["isError"] as? Bool ?? false
    }
  }

  private func handleExtensionUI(_ event: PiRPCClient.JSON) {
    guard let method = event["method"] as? String,
      let id = event["id"] as? String
    else { return }
    let title = event["title"] as? String ?? "Pi 扩展"
    switch method {
    case "select":
      extensionDialog = ExtensionDialog(
        id: id, title: title, kind: .select(options: event["options"] as? [String] ?? []))
    case "confirm":
      extensionDialog = ExtensionDialog(
        id: id, title: title, kind: .confirm(message: event["message"] as? String ?? ""))
    case "input", "editor":
      extensionDialog = ExtensionDialog(
        id: id,
        title: title,
        kind: .input(
          initialText: event["prefill"] as? String ?? "",
          placeholder: event["placeholder"] as? String ?? "",
          multiline: method == "editor"
        )
      )
    case "notify":
      messages.append(
        ChatEntry(
          id: UUID().uuidString, kind: .system, title: "通知", text: event["message"] as? String ?? ""
        ))
    case "setTitle":
      NSApp.mainWindow?.title = event["title"] as? String ?? "Pi Mac"
    case "set_editor_text":
      composerText = event["text"] as? String ?? ""
    case "setStatus":
      let key = event["statusKey"] as? String ?? "extension"
      let rawText = event["statusText"] as? String ?? ""
      if key == "codex-accounts-gui" {
        updateCodexAccounts(from: rawText)
        return
      }
      let text = Self.removingANSIEscapes(rawText)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        extensionStatuses[key] = text
      } else if key != "codex-accounts" {
        // 多账户扩展的最后一次额度信息需要常驻；其他临时扩展状态仍可主动清除。
        extensionStatuses.removeValue(forKey: key)
      }
    default:
      break
    }
  }

  private func updateCodexAccounts(from text: String) {
    guard !text.isEmpty,
      let data = text.data(using: .utf8),
      let payload = try? JSONSerialization.jsonObject(with: data) as? PiRPCClient.JSON,
      payload["version"] as? Int == 1,
      let rawAccounts = payload["accounts"] as? [PiRPCClient.JSON]
    else {
      codexAccounts = []
      geminiUsage = nil
      codexAccountsUpdatedAt = nil
      return
    }
    let active = payload["activeAccount"] as? String
    let defaultAccount = payload["defaultAccount"] as? String
    codexAccounts = rawAccounts.compactMap { raw in
      guard let name = raw["name"] as? String else { return nil }
      return CodexAccountStatus(
        name: name,
        isActive: name == active,
        isDefault: name == defaultAccount,
        isHidden: raw["hidden"] as? Bool ?? false,
        primary: Self.codexWindow(from: raw["primary"]),
        secondary: Self.codexWindow(from: raw["secondary"]),
        error: raw["error"] as? String
      )
    }.sorted {
      if $0.isActive != $1.isActive { return $0.isActive }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    if let rawGemini = payload["gemini"] as? PiRPCClient.JSON {
      let kind = rawGemini["kind"] as? String
      let quotas = (rawGemini["quotas"] as? [PiRPCClient.JSON] ?? []).compactMap {
        raw -> GeminiQuota? in
        guard let remaining = raw["remainingPercent"] as? Double else { return nil }
        return GeminiQuota(
          remainingPercent: remaining,
          resetAt: (raw["resetAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1_000) },
          window: raw["window"] as? String
        )
      }
      geminiUsage = GeminiUsageStatus(
        isConfigured: kind != "unconfigured",
        isActive: rawGemini["isActive"] as? Bool ?? false,
        quotas: quotas,
        error: rawGemini["error"] as? String
      )
    } else {
      geminiUsage = nil
    }
    if let milliseconds = payload["updatedAt"] as? Double {
      codexAccountsUpdatedAt = Date(timeIntervalSince1970: milliseconds / 1_000)
    }
  }

  nonisolated private static func codexWindow(from value: Any?) -> CodexUsageWindow? {
    guard let raw = value as? PiRPCClient.JSON,
      let remaining = raw["remainingPercent"] as? Double
    else { return nil }
    let resetAt = (raw["resetAt"] as? Double).map(Date.init(timeIntervalSince1970:))
    return CodexUsageWindow(
      remainingPercent: remaining,
      resetAt: resetAt,
      windowSeconds: raw["windowSeconds"] as? Double
    )
  }

  private func append(_ text: String, to id: String) {
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[index].text += text
  }

  private func appendSystemError(_ text: String) {
    messages.append(
      ChatEntry(id: UUID().uuidString, kind: .system, title: "错误", text: text, isError: true))
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

  private static func chatEntry(from message: PiRPCClient.JSON) -> ChatEntry? {
    guard let role = message["role"] as? String else { return nil }
    switch role {
    case "user":
      return ChatEntry(
        id: UUID().uuidString, kind: .user, title: "你", text: contentText(message["content"]))
    case "assistant":
      let text = contentText(message["content"])
      return text.isEmpty
        ? nil : ChatEntry(id: UUID().uuidString, kind: .assistant, title: "Pi", text: text)
    case "toolResult":
      return ChatEntry(
        id: message["toolCallId"] as? String ?? UUID().uuidString,
        kind: .tool,
        title: "工具 · \(message["toolName"] as? String ?? "tool")",
        text: contentText(message["content"]),
        isError: message["isError"] as? Bool ?? false,
        toolName: message["toolName"] as? String,
        diff: (message["details"] as? PiRPCClient.JSON)?["diff"] as? String
          ?? (message["details"] as? PiRPCClient.JSON)?["patch"] as? String
      )
    case "bashExecution":
      return ChatEntry(
        id: UUID().uuidString, kind: .tool, title: "命令", text: message["output"] as? String ?? "")
    default:
      return nil
    }
  }

  nonisolated private static func removingANSIEscapes(_ text: String) -> String {
    // 扩展沿用 TUI 的彩色状态文本；原生界面只保留其中的可读内容。
    let pattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.stringByReplacingMatches(in: text, range: range, withTemplate: "")
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

  private static func resultText(_ result: PiRPCClient.JSON) -> String {
    let text = contentText(result["content"])
    return text.isEmpty ? prettyJSON(result) : text
  }

  private static func prettyJSON(_ value: Any?) -> String {
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

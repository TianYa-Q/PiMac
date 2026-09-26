import Combine
import Foundation

struct TelegramUpdate: Decodable {
  let updateID: Int64
  let message: Message?
  let callbackQuery: CallbackQuery?

  enum CodingKeys: String, CodingKey {
    case updateID = "update_id"
    case message
    case callbackQuery = "callback_query"
  }

  struct Message: Decodable {
    let date: TimeInterval
    let from: Sender?
    let chat: Chat
    let text: String?
    let caption: String?
    let photo: [Photo]?
  }
  struct Photo: Decodable {
    let fileID: String
    let fileSize: Int?

    enum CodingKeys: String, CodingKey {
      case fileID = "file_id"
      case fileSize = "file_size"
    }
  }
  struct CallbackQuery: Decodable {
    let id: String
    let from: Sender
    let message: CallbackMessage?
    let data: String?
  }
  struct CallbackMessage: Decodable {
    let chat: Chat
  }
  struct Sender: Decodable {
    let id: Int64
    let isBot: Bool

    enum CodingKeys: String, CodingKey {
      case id
      case isBot = "is_bot"
    }
  }
  struct Chat: Decodable {
    let id: Int64
    let type: String
  }

  func authorizedCallback(userID: Int64) -> (id: String, command: String)? {
    guard let callbackQuery, callbackQuery.from.id == userID,
      !callbackQuery.from.isBot, callbackQuery.message?.chat.id == userID,
      callbackQuery.message?.chat.type == "private", let data = callbackQuery.data,
      Self.isAllowedCommand(data)
    else { return nil }
    return (callbackQuery.id, data)
  }

  private static func isAllowedCommand(_ data: String) -> Bool {
    if ["/sessions", "/projects", "/status", "/usage", "/accounts", "/new", "/compact", "/stop", "/last", "/help", "/model", "/thinking"].contains(data) {
      return true
    }
    if data.hasPrefix("session:"), UUID(uuidString: String(data.dropFirst(8))) != nil { return true }
    if data.hasPrefix("/sessions "), let page = Int(data.dropFirst(10)) { return page > 0 }
    if data.hasPrefix("/projects "), let page = Int(data.dropFirst(10)) { return page > 0 }
    if data.hasPrefix("/model "), let page = Int(data.dropFirst(7)) { return page > 0 }
    if data.hasPrefix("model:"), let number = Int(data.dropFirst(6)) { return number > 0 }
    if data.hasPrefix("account:"), let number = Int(data.dropFirst(8)) { return number > 0 }
    if data.hasPrefix("thinking:") {
      return PiModel.thinkingLevelOrder.contains(String(data.dropFirst(9)))
    }
    guard data.hasPrefix("select:"), let number = Int(data.dropFirst(7)) else { return false }
    return number > 0
  }

  func authorizedMessage(userID: Int64, since: Date) -> Message? {
    guard let message, message.chat.type == "private", message.chat.id == userID,
      message.from?.id == userID, message.from?.isBot == false,
      message.date >= since.timeIntervalSince1970
    else { return nil }
    return message
  }

  func authorizedText(userID: Int64, since: Date) -> String? {
    authorizedMessage(userID: userID, since: since)?.text
  }
}

/// A bounded FIFO per remote session; requests stay local until the preceding turn settles.
struct TelegramPromptQueue<Element> {
  private(set) var items: [Element] = []
  var count: Int { items.count }
  var isEmpty: Bool { items.isEmpty }
  var first: Element? { items.first }

  @discardableResult
  mutating func append(_ item: Element, maxCount: Int = 50) -> Int? {
    guard items.count < maxCount else { return nil }
    items.append(item)
    return items.count
  }

  @discardableResult
  mutating func removeFirst() -> Element? {
    guard !items.isEmpty else { return nil }
    return items.removeFirst()
  }
}

enum TelegramTokenStore {
  private static let key = "telegram.botToken"

  static func load(defaults: UserDefaults = .standard) -> String {
    defaults.string(forKey: key) ?? ""
  }

  static func save(_ token: String, defaults: UserDefaults = .standard) {
    if token.isEmpty {
      defaults.removeObject(forKey: key)
    } else {
      defaults.set(token, forKey: key)
    }
  }
}

@MainActor
final class TelegramControl: ObservableObject {
  @Published private(set) var status = "未启用"
  @Published private(set) var connectionState: ConnectionState = .disconnected
  private weak var workspace: WorkspaceModel?
  private var task: Task<Void, Never>?
  private var remoteModels: [String: AppModel] = [:]
  private struct SessionTarget {
    let project: String
    let modelID: ObjectIdentifier
    let sessionPath: String
  }
  private var sessionTargets: [String: SessionTarget] = [:]
  private var sessionButtons: [[[String: String]]] = []
  private let projectKey = "telegram.projectPath"
  private let sessionsKey = "telegram.sessionPaths"
  private var replies: [UUID: AnyCancellable] = [:]
  private var pendingModels: Set<ObjectIdentifier> = []
  private struct RemotePrompt {
    let text: String
    let attachments: [PromptAttachment]
    let token: String
    let userID: Int64
    let generation: UUID
  }
  private var promptQueues: [ObjectIdentifier: TelegramPromptQueue<RemotePrompt>] = [:]
  private var queueObservations: [ObjectIdentifier: AnyCancellable] = [:]
  private var sendingReplies = 0
  private struct UnsentReply {
    let id: UUID
    let sessionPath: String
    let text: String
  }
  private var unsentReplies: [String: UnsentReply] = [:]
  private var generation = UUID()
  private let defaults = UserDefaults.standard
  static let allowedUpdates = ["message", "callback_query"]

  var enabled: Bool { defaults.bool(forKey: "telegram.enabled") }
  var userID: String { defaults.string(forKey: "telegram.userID") ?? "" }

  var canRestartSafely: Bool {
    pendingModels.isEmpty && replies.isEmpty && sendingReplies == 0 && remoteModels.values.allSatisfy { model in
      model.canRestartSafely && !(workspace?.extensionUI.hasPendingRequests(from: model) ?? true)
    }
  }

  func start(workspace: WorkspaceModel) {
    self.workspace = workspace
    restart()
  }

  func configure(token: String, userID: String, enabled: Bool) throws {
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    let userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    if enabled {
      guard let id = Int64(userID), id > 0,
        token.range(of: #"^[0-9]+:[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
      else { throw ConfigurationError.invalid }
    }
    TelegramTokenStore.save(token)
    defaults.set(userID, forKey: "telegram.userID")
    defaults.set(enabled, forKey: "telegram.enabled")
    restart()
  }

  enum ConfigurationError: LocalizedError {
    case invalid
    var errorDescription: String? { "请输入有效的 Bot Token 和正整数 Telegram 用户 ID。" }
  }

  func stop() {
    generation = UUID()
    task?.cancel()
    task = nil
    replies.removeAll()
    pendingModels.removeAll()
    queueObservations.removeAll()
    for queue in promptQueues.values {
      for prompt in queue.items {
        for attachment in prompt.attachments { try? FileManager.default.removeItem(at: attachment.url) }
      }
    }
    promptQueues.removeAll()
    for model in remoteModels.values {
      rememberSession(model)
      model.disconnect()
    }
    remoteModels.removeAll()
    status = "已停止"
    connectionState = .disconnected
  }

  private func restart() {
    stop()
    guard enabled else {
      status = "未启用"
      return
    }
    let token = TelegramTokenStore.load()
    guard !token.isEmpty, let id = Int64(userID), id > 0 else {
      status = "配置无效或未设置 Bot Token"
      connectionState = .failed("配置无效")
      return
    }
    status = "连接中…"
    connectionState = .connecting
    let since = Date()
    let generation = generation
    task = Task { [weak self] in
      var offset: Int64 = 0
      var commandsRegistered = false
      while !Task.isCancelled {
        do {
          if !commandsRegistered {
            let registered: Bool = try await Self.call(
              token: token, method: "setMyCommands",
              body: ["commands": Self.botCommands, "scope": ["type": "chat", "chat_id": id]])
            guard registered else { throw APIError.failed }
            commandsRegistered = true
            guard self?.generation == generation else { break }
            self?.status = "已连接 · 仅允许用户 \(id)"
            self?.connectionState = .connected
          }
          let updates: [TelegramUpdate] = try await Self.call(
            token: token, method: "getUpdates",
            body: ["offset": offset, "timeout": 25, "allowed_updates": Self.allowedUpdates])
          guard !Task.isCancelled else { break }
          guard self?.generation == generation else { break }
          self?.status = "已连接 · 仅允许用户 \(id)"
          self?.connectionState = .connected
          for update in updates {
            guard !Task.isCancelled else { break }
            offset = max(offset, update.updateID + 1)
            guard let self else { continue }
            if let callback = update.authorizedCallback(userID: id) {
              let _: Bool = try await Self.call(
                token: token, method: "answerCallbackQuery", body: ["callback_query_id": callback.id])
              guard self.generation == generation else { break }
              let delivery = self.pendingDelivery(for: callback.command)
              let reply = await self.handle(callback.command, token: token, userID: id, generation: generation, fromCallback: true)
              try await Self.send(
                reply, token: token, userID: id,
                keyboard: self.keyboard(for: callback.command))
              self.markDelivered(delivery)
            } else if let message = update.authorizedMessage(userID: id, since: since) {
              if let photo = message.photo?.last {
                let reply: String
                if let size = photo.fileSize, size > Self.maxImageBytes {
                  reply = "图片过大，请发送不超过 20 MB 的图片。"
                } else {
                  do {
                    let attachment = try await Self.downloadPhoto(photo, token: token)
                    guard self.generation == generation, !Task.isCancelled else { break }
                    reply = await self.handle(
                      message.caption ?? "", attachments: [attachment], token: token,
                      userID: id, generation: generation)
                  } catch {
                    reply = "图片下载失败或超过 20 MB，请稍后重试。"
                  }
                }
                try await Self.send(reply, token: token, userID: id)
              } else if let text = message.text {
                let delivery = self.pendingDelivery(for: text)
                let reply = await self.handle(text, token: token, userID: id, generation: generation)
                try await Self.send(reply, token: token, userID: id, keyboard: self.keyboard(for: text))
                self.markDelivered(delivery)
              }
            }
          }
        } catch {
          guard !Task.isCancelled else { break }
          // Never display URLSession errors: their URLs contain the bot secret.
          guard self?.generation == generation else { break }
          self?.status = "Telegram 连接或发送失败，5 秒后重试（检查网络、Token、Webhook 或重复运行的 Bot）"
          self?.connectionState = .failed("连接或发送失败")
          try? await Task.sleep(for: .seconds(5))
        }
      }
    }
  }

  static let botCommands: [[String: String]] = [
    ["command": "projects", "description": "查看项目列表"],
    ["command": "sessions", "description": "查看进行中的会话并快速切换"],
    ["command": "status", "description": "查看 Telegram 会话状态"],
    ["command": "model", "description": "选择 Telegram 模型"],
    ["command": "thinking", "description": "选择 Telegram 推理强度"],
    ["command": "usage", "description": "查看额度及切换 Codex 账户"],
    ["command": "accounts", "description": "查看额度并切换 Codex 账户"],
    ["command": "new", "description": "新建 Telegram 会话"],
    ["command": "compact", "description": "压缩 Telegram 会话上下文"],
    ["command": "stop", "description": "停止当前任务"],
    ["command": "last", "description": "领取未送达的回复"],
    ["command": "help", "description": "查看帮助"],
  ]

  static let help = """
    Pi Mac · Telegram 远程控制
    项目选择和会话与桌面独立。先用 /projects 下方的按钮选项目，随后会自动显示会话状态；直接发送文本或照片（可附说明）即可执行任务。正在执行的消息会依次排队，前一条完成后再处理下一条。

    📁 项目与会话
    /projects  选择项目
    /sessions  查看 Telegram 会话（执行中优先），点击按钮切换
    /status  查看连接、会话、模型及推理强度
    /new  在当前项目新建会话
    /compact  空闲时压缩当前会话上下文

    ⚙️ 设置与额度
    /model  选择 Telegram 模型
    /thinking  选择 Telegram 推理强度
    /usage  查看账户额度并通过按钮切换 Codex 账户
    /accounts  查看额度并切换 Codex 账户

    ⏹ 任务与回复
    /stop  停止当前任务
    /last  领取未送达的回复（已回传的不重复发送）
    /help  查看本帮助

    也可点击下方按钮操作。扩展确认仍需在 Mac 上完成。
    """

  private func keyboard(for text: String) -> [[[String: String]]]? {
    let command = text.split(maxSplits: 1, whereSeparator: \.isWhitespace).first
      .map { String($0).components(separatedBy: "@")[0].lowercased() } ?? ""
    guard ["/sessions", "/start", "/help", "/projects", "/status", "/usage", "/accounts", "/new", "/compact", "/stop", "/last", "/model", "/thinking"]
      .contains(command) || command.hasPrefix("select:") || command.hasPrefix("model:")
      || command.hasPrefix("thinking:") || command.hasPrefix("account:") || command.hasPrefix("session:")
    else { return nil }
    func button(_ title: String, _ action: String) -> [String: String] {
      ["text": title, "callback_data": action]
    }
    var rows: [[[String: String]]] = []
    if command == "/sessions" { rows += sessionButtons }
    if command == "/projects", let workspace {
      let parts = text.split(separator: " ")
      let page = parts.count == 2 ? min(max(1, Int(parts[1]) ?? 1), max(1, (workspace.projects.count + 29) / 30)) : 1
      let start = min((page - 1) * 30, workspace.projects.count)
      let buttons = workspace.projects.dropFirst(start).prefix(30).enumerated().map { index, project in
        button("\(start + index + 1). \(String(project.name.prefix(24)))", "select:\(start + index + 1)")
      }
      for offset in stride(from: 0, to: buttons.count, by: 2) {
        rows.append(Array(buttons[offset..<min(offset + 2, buttons.count)]))
      }
      if workspace.projects.count > 30 {
        var navigation: [[String: String]] = []
        if page > 1 { navigation.append(button("⬅️ 上一页", "/projects \(page - 1)")) }
        if start + 30 < workspace.projects.count {
          navigation.append(button("下一页 ➡️", "/projects \(page + 1)"))
        }
        if !navigation.isEmpty { rows.append(navigation) }
      }
    }
    if (command == "/model" || command.hasPrefix("model:")), let workspace,
      let model = remoteModel(in: workspace) {
      model.refreshModelPreferences()
      let parts = text.split(separator: " ")
      let page = command.hasPrefix("model:")
        ? ((Int(command.dropFirst(6)) ?? 1) - 1) / 20 + 1
        : (parts.count == 2 ? Int(parts[1]) ?? 1 : 1)
      let start = max(0, min(page - 1, max(0, (model.models.count - 1) / 20))) * 20
      let choices = model.models.dropFirst(start).prefix(20).enumerated().map { index, item in
        button("\(item.id == model.selectedModelId ? "✓ " : "")\(String(item.id.prefix(45)))", "model:\(start + index + 1)")
      }
      for offset in stride(from: 0, to: choices.count, by: 2) {
        rows.append(Array(choices[offset..<min(offset + 2, choices.count)]))
      }
      var nav: [[String: String]] = []
      if start > 0 { nav.append(button("⬅️ 上一页", "/model \(start / 20)")) }
      if start + 20 < model.models.count {
        nav.append(button("下一页 ➡️", "/model \(start / 20 + 2)"))
      }
      if !nav.isEmpty { rows.append(nav) }
    }
    if (command == "/thinking" || command.hasPrefix("thinking:")), let workspace,
      let model = remoteModel(in: workspace) {
      rows.append(model.thinkingLevels.map { level in
        button("\(level == model.selectedThinkingLevel ? "✓ " : "")\(level)", "thinking:\(level)")
      })
    }
    if command == "/usage" || command == "/accounts" || command.hasPrefix("account:") {
      let model = workspace.flatMap { remoteModel(in: $0) }
      let accounts = workspace?.extensionUI.usage(for: model).accounts ?? []
      let choices = accounts.enumerated().map { index, account in
        button("\(account.isActive ? "✓ " : "")\(String(account.name.prefix(35)))", "account:\(index + 1)")
      }
      for offset in stride(from: 0, to: choices.count, by: 2) {
        rows.append(Array(choices[offset..<min(offset + 2, choices.count)]))
      }
    }
    rows += [
      [button("📁 项目", "/projects"), button("📊 状态", "/status"), button("📈 额度/账户", "/usage")],
      [button("🗂 会话", "/sessions"), button("🤖 模型", "/model"), button("🧠 推理", "/thinking")],
      [button("🆕 新会话", "/new"), button("🗜️ 压缩", "/compact"), button("⏹ 停止", "/stop")],
      [button("📨 未送达回复", "/last"), button("❔ 帮助", "/help")],
    ]
    return rows
  }

  private func remoteModel(in workspace: WorkspaceModel) -> AppModel? {
    guard let path = defaults.string(forKey: projectKey),
      let project = workspace.projects.first(where: { $0.id == path }) ?? workspace.projects.first
    else { return nil }
    if let model = remoteModels[project.id] {
      if !model.isProcessRunning, case .disconnected = model.connectionState {
        model.resumeProcess(
          sessionPath: model.currentSessionPath.isEmpty ? nil : model.currentSessionPath,
          continueLastSession: false)
      }
      return model
    }
    let savedPaths = defaults.dictionary(forKey: sessionsKey) as? [String: String] ?? [:]
    let sessionPath = savedPaths[project.id].flatMap {
      FileManager.default.fileExists(atPath: $0) ? $0 : nil
    }
    let model = AppModel(
      startupProjectURL: project.url, continueLastSession: false,
      startupSessionPath: sessionPath, restoreLastProjectOnLaunch: false,
      remembersDesktopProject: false,
      modelPreferenceKey: "telegram.selectedModelID",
      thinkingPreferenceKey: "telegram.thinkingLevels")
    model.extensionUI = workspace.extensionUI
    remoteModels[project.id] = model
    return model
  }

  private func sessionsMessage(page: Int, in workspace: WorkspaceModel) -> String {
    sessionTargets.removeAll()
    sessionButtons.removeAll()
    let projects = Set(workspace.projects.map(\.id))
    let entries = remoteModels.filter { projects.contains($0.key) }.sorted {
      let lhs = $0.value.isBusy || pendingModels.contains(ObjectIdentifier($0.value))
        || promptQueues[ObjectIdentifier($0.value)]?.isEmpty == false
      let rhs = $1.value.isBusy || pendingModels.contains(ObjectIdentifier($1.value))
        || promptQueues[ObjectIdentifier($1.value)]?.isEmpty == false
      return lhs != rhs ? lhs : $0.key < $1.key
    }
    guard !entries.isEmpty else { return "暂无已打开的 Telegram 会话。请用 /projects 选择项目。" }
    let page = min(max(1, page), (entries.count + 9) / 10)
    let start = (page - 1) * 10
    var lines = ["🗂 Telegram 会话 · \(page)/\((entries.count + 9) / 10)"]
    for (index, entry) in entries.dropFirst(start).prefix(10).enumerated() {
      let (project, model) = entry
      let id = ObjectIdentifier(model)
      let queued = promptQueues[id]?.count ?? 0
      let busy = model.isBusy || pendingModels.contains(id)
      let current = defaults.string(forKey: projectKey) == project
      let title = Self.sessionListTitle(name: model.sessionName,
        firstPrompt: model.messages.first(where: { $0.kind == .user })?.text)
      let state = busy ? "执行中" : (model.isLoadingConfiguration ? "连接中" : "空闲")
      let projectName = model.projectURL?.lastPathComponent ?? project
      lines.append("\n\(start + index + 1). \(current ? "✓ 当前 · " : "")\(projectName) · \(state)\(queued > 0 ? " · 排队 \(queued)" : "")\n\(title)")
      let token = UUID().uuidString
      sessionTargets[token] = SessionTarget(project: project, modelID: id, sessionPath: model.currentSessionPath)
      sessionButtons.append([["text": "\(current ? "✓ " : "")\(start + index + 1). \(String(projectName.prefix(20))) · \(String(title.prefix(25)))",
        "callback_data": "session:\(token)"]])
    }
    var navigation: [[String: String]] = []
    if page > 1 { navigation.append(["text": "⬅️ 上一页", "callback_data": "/sessions \(page - 1)"]) }
    if start + 10 < entries.count { navigation.append(["text": "下一页 ➡️", "callback_data": "/sessions \(page + 1)"]) }
    if !navigation.isEmpty { sessionButtons.append(navigation) }
    lines.append("\n点击按钮切换；其他任务不会停止。仅列出本次运行已打开的 Telegram 会话，不包含桌面会话。")
    return lines.joined(separator: "\n")
  }

  static func sessionListTitle(name: String, firstPrompt: String?) -> String {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = name.isEmpty ? (firstPrompt ?? "新会话") : name
    let title = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return title.isEmpty ? "新会话" : String(title.prefix(100))
  }

  private func rememberSession(_ model: AppModel) {
    guard let path = model.projectURL?.standardizedFileURL.path else { return }
    var sessions = defaults.dictionary(forKey: sessionsKey) as? [String: String] ?? [:]
    if model.currentSessionPath.isEmpty {
      sessions.removeValue(forKey: path)
    } else {
      sessions[path] = model.currentSessionPath
    }
    defaults.set(sessions, forKey: sessionsKey)
  }

  private func pendingReply(for model: AppModel) -> UnsentReply? {
    guard let project = model.projectURL?.standardizedFileURL.path,
      let reply = unsentReplies[project], reply.sessionPath == model.currentSessionPath
    else { return nil }
    return reply
  }

  private func pendingDelivery(for text: String) -> (project: String, id: UUID)? {
    guard text == "/last", let workspace, let model = remoteModel(in: workspace),
      let project = model.projectURL?.standardizedFileURL.path,
      let reply = pendingReply(for: model) else { return nil }
    return (project, reply.id)
  }

  private func markDelivered(_ delivery: (project: String, id: UUID)?) {
    guard let delivery, unsentReplies[delivery.project]?.id == delivery.id else { return }
    unsentReplies.removeValue(forKey: delivery.project)
  }

  // The remote AppModel starts its RPC process on the next main-actor turn. On the
  // first /status after launch, wait for that startup and configuration to finish
  // instead of immediately reporting the temporary "待连接" state.
  static func waitForSessionStatus(in model: AppModel) async {
    let deadline = Date().addingTimeInterval(17)
    while !Task.isCancelled && Date() < deadline {
      switch model.connectionState {
      case .connected where !model.isLoadingConfiguration, .failed:
        return
      default:
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  private func sessionStatus(for model: AppModel) -> String {
    Self.statusMessage(
      project: model.projectURL?.lastPathComponent ?? "未选择", session: model.sessionName,
      sessionPath: model.currentSessionPath,
      firstPrompt: model.messages.first(where: { $0.kind == .user })?.text,
      connection: model.connectionState, busy: model.isBusy,
      loading: model.isLoadingConfiguration, detail: model.statusText,
      model: model.selectedModelId, thinking: model.selectedThinkingLevel,
      contextPercent: model.stats?.contextPercent,
      account: workspace?.extensionUI.usage(for: model).accounts.first(where: \.isActive)?.name)
  }

  private func handle(
    _ text: String, attachments: [PromptAttachment] = [], token: String, userID: Int64,
    generation: UUID, fromCallback: Bool = false
  ) async -> String {
    var submittedAttachments = false
    defer {
      if !submittedAttachments {
        for attachment in attachments { try? FileManager.default.removeItem(at: attachment.url) }
      }
    }
    guard let workspace else { return "工作区不可用" }
    let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    let command = attachments.isEmpty
      ? (parts.first.map { String($0).components(separatedBy: "@")[0].lowercased() } ?? "") : ""
    switch command {
    case "/start", "/help": return Self.help
    case "/sessions":
      return sessionsMessage(page: parts.count == 2 ? Int(parts[1]) ?? 1 : 1, in: workspace)
    case let action where action.hasPrefix("session:") && fromCallback:
      guard let target = sessionTargets[String(action.dropFirst(8))],
        workspace.projects.contains(where: { $0.id == target.project }),
        let targetModel = remoteModels[target.project],
        ObjectIdentifier(targetModel) == target.modelID,
        targetModel.currentSessionPath == target.sessionPath
      else { return "会话列表已变化，请重新使用 /sessions。" }
      if let previousPath = defaults.string(forKey: projectKey),
        let previous = remoteModels[previousPath] { rememberSession(previous) }
      defaults.set(target.project, forKey: projectKey)
      _ = remoteModel(in: workspace)
      return "已切换 Telegram 会话，后续消息将发送到此会话（其他任务继续运行）。\n\n" + sessionStatus(for: targetModel)
    case "/projects":
      let page = parts.count == 2 ? min(max(1, Int(parts[1]) ?? 1), max(1, (workspace.projects.count + 29) / 30)) : 1
      let start = min((page - 1) * 30, workspace.projects.count)
      return workspace.projects.isEmpty
        ? "请先在 Mac 上添加项目。"
        : workspace.projects.dropFirst(start).prefix(30).enumerated()
          .map { "\(start + $0.offset + 1). \($0.element.name) — \($0.element.id)" }.joined(separator: "\n")
          + "\n点击下方按钮切换项目。"
    case let action where action.hasPrefix("select:") && fromCallback:
      guard let number = Int(action.dropFirst(7)),
        workspace.projects.indices.contains(number - 1)
      else { return "请使用 /projects 下方的项目按钮切换。" }
      let project = workspace.projects[number - 1]
      let previousPath = defaults.string(forKey: projectKey) ?? workspace.projects.first?.id ?? ""
      if let previous = remoteModels[previousPath],
        previous.projectURL?.standardizedFileURL.path != project.id,
        promptQueues[ObjectIdentifier(previous)]?.isEmpty != false
      {
        rememberSession(previous)
        previous.suspendProcess()
      }
      defaults.set(project.id, forKey: projectKey)
      guard let model = remoteModel(in: workspace) else { return "请先在 Mac 上添加项目。" }
      await Self.waitForSessionStatus(in: model)
      guard generation == self.generation, !Task.isCancelled else {
        return "连接已重置，请重新发送命令。"
      }
      return "Telegram 已选择 \(project.name)（不改变桌面选择）。\n\n" + sessionStatus(for: model)
    default: break
    }
    if command == "/usage" || command == "/accounts" {
      let model = remoteModel(in: workspace)
      let usage = workspace.extensionUI.usage(for: model)
      return Self.usageMessage(accounts: usage.accounts, gemini: usage.gemini, updatedAt: usage.updatedAt)
    }
    guard let model = remoteModel(in: workspace) else { return "请先在 Mac 上添加项目。" }
    switch command {
    case let action where action.hasPrefix("account:") && fromCallback:
      let accounts = workspace.extensionUI.usage(for: model).accounts
      guard let number = Int(action.dropFirst(8)), accounts.indices.contains(number - 1)
      else { return "账户列表已变化，请重新使用 /usage。" }
      guard model.clientConnectedForCommands, model.canRestartSafely,
        promptQueues[ObjectIdentifier(model)]?.isEmpty != false,
        !pendingModels.contains(ObjectIdentifier(model)),
        !workspace.extensionUI.hasPendingRequests(from: model)
      else { return "会话正在执行或尚未就绪，请稍后再切换账户。" }
      let account = accounts[number - 1]
      if account.isActive { return "当前已使用 Codex 账户 \(account.name)。" }
      model.switchCodexAccount(to: account.name)
      return "已请求切换到 Codex 账户 \(account.name)，请用 /status 确认。"
    case "/model":
      model.refreshModelPreferences()
      let page = min(max(1, (model.models.count + 19) / 20), parts.count == 2 ? max(1, Int(parts[1]) ?? 1) : 1)
      let start = min((page - 1) * 20, model.models.count)
      let list = model.models.dropFirst(start).prefix(20).enumerated().map {
        "\(start + $0.offset + 1). \($0.element.id)\($0.element.id == model.selectedModelId ? " ✓" : "")"
      }
      return list.isEmpty ? "模型列表尚未就绪，请稍后重试。" : "🤖 Telegram 模型（\(page)）\n" + list.joined(separator: "\n") + "\n点击下方按钮选择。"
    case "/thinking":
      return "🧠 Telegram 推理强度：\(model.selectedThinkingLevel)\n可选：\(model.thinkingLevels.joined(separator: "、"))\n点击下方按钮选择。"
    case let action where action.hasPrefix("model:") && fromCallback:
      model.refreshModelPreferences()
      guard let number = Int(action.dropFirst(6)), model.models.indices.contains(number - 1)
      else { return "模型列表已变化，请重新使用 /model。" }
      guard model.clientConnectedForCommands, model.canRestartSafely,
        !pendingModels.contains(ObjectIdentifier(model)),
        !workspace.extensionUI.hasPendingRequests(from: model)
      else { return "会话正在执行或尚未就绪，请稍后再试。" }
      let choice = model.models[number - 1]
      model.changeModel(to: choice.id)
      return "已请求将 Telegram 模型设为 \(choice.id)，请用 /status 确认。"
    case let action where action.hasPrefix("thinking:") && fromCallback:
      let level = String(action.dropFirst(9))
      guard model.thinkingLevels.contains(level) else { return "当前模型不支持此强度，请重新使用 /thinking。" }
      guard model.clientConnectedForCommands, model.canRestartSafely,
        !pendingModels.contains(ObjectIdentifier(model)),
        !workspace.extensionUI.hasPendingRequests(from: model)
      else { return "会话正在执行或尚未就绪，请稍后再试。" }
      model.changeThinkingLevel(to: level)
      return "已请求将 Telegram 推理强度设为 \(level)，请用 /status 确认。"
    case "/status":
      await Self.waitForSessionStatus(in: model)
      return sessionStatus(for: model)
    case "/compact":
      await Self.waitForSessionStatus(in: model)
      guard generation == self.generation, !Task.isCancelled else {
        return "连接已重置，请重新发送命令。"
      }
      guard model.canRestartSafely, model.clientConnectedForCommands,
        promptQueues[ObjectIdentifier(model)]?.isEmpty != false,
        !pendingModels.contains(ObjectIdentifier(model)),
        !workspace.extensionUI.hasPendingRequests(from: model)
      else { return "会话未就绪、正在执行或有任务排队，请等待完成后再压缩。" }
      guard !model.currentSessionPath.isEmpty else { return "当前尚无会话内容，发送消息后再压缩。" }
      model.compact()
      return "已开始压缩当前 Telegram 会话的上下文。完成后可用 /status 查看新的占比。"
    case "/last":
      return pendingReply(for: model)?.text ?? "暂无待领取的回复。任务完成后会自动回传，无需重复获取。"
    case "/stop":
      let modelID = ObjectIdentifier(model)
      let cancelled = promptQueues.removeValue(forKey: modelID)?.items ?? []
      queueObservations.removeValue(forKey: modelID)
      for prompt in cancelled {
        for attachment in prompt.attachments { try? FileManager.default.removeItem(at: attachment.url) }
      }
      model.abort()
      return cancelled.isEmpty
        ? "已请求停止当前会话任务。"
        : "已请求停止当前会话任务，并取消 \(cancelled.count) 条等待中的消息。"
    case "/new":
      guard !model.isBusy, !model.isLoadingConfiguration, model.queuedPrompts.isEmpty,
        promptQueues[ObjectIdentifier(model)]?.isEmpty != false,
        !pendingModels.contains(ObjectIdentifier(model)),
        !workspace.extensionUI.hasPendingRequests(from: model)
      else { return "请先结束任务并处理扩展确认，再新建会话。" }
      guard model.canReuseProcessForNewSession else { return "会话尚未就绪，请稍后重试。" }
      var created: Bool?
      model.newSession { [weak self, weak model] succeeded in
        created = succeeded
        guard succeeded, let self, let model else { return }
        self.rememberSession(model)
        if let project = model.projectURL?.standardizedFileURL.path {
          self.unsentReplies.removeValue(forKey: project)
        }
        self.workspace?.remoteSessionChanged(in: model.projectURL, sessionPath: model.currentSessionPath)
      }
      // newSession completes before its configuration refresh. Wait for the actual state
      // so the response matches what /status would show, without requiring another click.
      let deadline = Date().addingTimeInterval(20)
      while generation == self.generation && !Task.isCancelled && Date() < deadline {
        if created == false { return "新建 Telegram 会话失败。\n\n" + sessionStatus(for: model) }
        if created == true && !model.isLoadingConfiguration { return sessionStatus(for: model) }
        try? await Task.sleep(for: .milliseconds(100))
      }
      return sessionStatus(for: model)
    default:
      if command.hasPrefix("/") { return "未知命令。\n" + Self.help }
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
      else { return Self.help }
      // A freshly restored Telegram session starts its RPC process asynchronously. Accept
      // the first prompt after startup instead of rejecting it during the connecting window.
      await Self.waitForSessionStatus(in: model)
      guard generation == self.generation, !Task.isCancelled else {
        return "连接已重置，请重新发送任务。"
      }
      guard model.clientConnectedForCommands, !model.isLoadingConfiguration
      else { return "当前会话未就绪，请稍后再试。" }
      let prompt = RemotePrompt(
        text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "请分析这张图片。" : text,
        attachments: attachments, token: token, userID: userID, generation: generation)
      let modelID = ObjectIdentifier(model)
      if !canSubmitRemotePrompt(in: model) || promptQueues[modelID]?.isEmpty == false {
        guard let position = promptQueues[modelID, default: .init()].append(prompt)
        else { return "等待队列已满，请稍后再试。" }
        observeQueue(in: model)
        submittedAttachments = true
        // If the previous turn settled while this update was being handled, drain now.
        scheduleQueueDrain(for: model)
        return "已排队（等待队列第 \(position) 位）。完成后会自动回传回复。"
      }
      submitRemotePrompt(prompt, in: model)
      submittedAttachments = true
      return "已发送到「\(model.projectURL?.lastPathComponent ?? "当前项目")」。完成后会自动回传回复。"
    }
  }

  private func canSubmitRemotePrompt(in model: AppModel) -> Bool {
    model.clientConnectedForCommands && model.canRestartSafely
      && !pendingModels.contains(ObjectIdentifier(model))
      && workspace?.extensionUI.hasPendingRequests(from: model) == false
  }

  private func observeQueue(in model: AppModel) {
    let id = ObjectIdentifier(model)
    guard queueObservations[id] == nil else { return }
    var updates: [AnyPublisher<Void, Never>] = [
      model.$isStreaming.map { _ in () }.eraseToAnyPublisher(),
      model.$isCompacting.map { _ in () }.eraseToAnyPublisher(),
      model.$queuedPrompts.map { _ in () }.eraseToAnyPublisher(),
      model.$connectionState.map { _ in () }.eraseToAnyPublisher(),
      model.$isLoadingConfiguration.map { _ in () }.eraseToAnyPublisher(),
    ]
    if let extensionUI = workspace?.extensionUI {
      updates.append(extensionUI.$dialog.map { _ in () }.eraseToAnyPublisher())
    }
    queueObservations[id] = Publishers.MergeMany(updates).sink { [weak self, weak model] _ in
      guard let self, let model else { return }
      // @Published emits before the value changes; check after the update is applied.
      self.scheduleQueueDrain(for: model)
    }
  }

  private func scheduleQueueDrain(for model: AppModel) {
    Task { @MainActor [weak self, weak model] in
      guard let self, let model else { return }
      let id = ObjectIdentifier(model)
      guard self.canSubmitRemotePrompt(in: model),
        let first = self.promptQueues[id]?.first, first.generation == self.generation
      else { return }
      self.promptQueues[id]?.removeFirst()
      if self.promptQueues[id]?.isEmpty == true {
        self.promptQueues.removeValue(forKey: id)
        self.queueObservations.removeValue(forKey: id)
      }
      self.submitRemotePrompt(first, in: model)
    }
  }

  private func submitRemotePrompt(_ prompt: RemotePrompt, in model: AppModel) {
    let token = prompt.token
    let userID = prompt.userID
    let generation = prompt.generation
    let attachments = prompt.attachments
    let modelID = ObjectIdentifier(model)
    let key = UUID()
    pendingModels.insert(modelID)
    let existing = Set(model.messages.map(\.id))
    var started = false
    replies[key] = model.$isStreaming.sink { [weak self, weak model] streaming in
      if streaming {
        started = true
        return
      }
      guard started else { return }
      Task { @MainActor [weak self, weak model] in
        guard let self, self.generation == generation, let model else { return }
        guard self.replies.removeValue(forKey: key) != nil else { return }
        self.pendingModels.remove(modelID)
        self.scheduleQueueDrain(for: model)
        self.rememberSession(model)
        self.workspace?.remoteSessionChanged(
          in: model.projectURL, sessionPath: model.currentSessionPath)
        let output = Self.latestReply(in: model.messages, excluding: existing)
        let project = model.projectURL?.standardizedFileURL.path
        // Only failed deliveries are available through /last; do not race automatic sends.
        let previousReply = project.flatMap { self.unsentReplies[$0]?.id }
        self.sendingReplies += 1
        defer { self.sendingReplies -= 1 }
        do {
          try await Self.send(
            output ?? "任务已结束，没有文本回复。", token: token, userID: userID,
            keyboard: self.keyboard(for: "/status"),
            allowed: { [weak self] in self?.generation == generation })
          self.markDelivered(
            project.flatMap { project in
              previousReply.map { (project, $0) }
            })
        } catch {
          if self.generation == generation {
            if let project, let output {
              self.unsentReplies[project] = UnsentReply(
                id: UUID(), sessionPath: model.currentSessionPath, text: output)
            }
            self.status = "回复发送失败，可使用 /last 再次获取。"
          }
        }
      }
    }
    model.sendRemotePrompt(prompt.text, attachments: attachments) {
      [weak self, weak model] accepted in
      if !accepted {
        for attachment in attachments { try? FileManager.default.removeItem(at: attachment.url) }
      }
      if accepted, let self, self.generation == generation, let model {
        self.workspace?.remoteSessionChanged(
          in: model.projectURL, sessionPath: model.currentSessionPath)
      }
      guard !accepted, let self, self.generation == generation,
        self.replies.removeValue(forKey: key) != nil
      else { return }
      self.pendingModels.remove(modelID)
      if let model { self.scheduleQueueDrain(for: model) }
      Task { @MainActor [weak self] in
        guard self?.generation == generation else { return }
        guard let self else { return }
        self.sendingReplies += 1
        defer { self.sendingReplies -= 1 }
        do {
          try await Self.send(
            "任务提交失败，请在 Mac 上查看错误并使用 /status 检查状态。", token: token, userID: userID,
            keyboard: self.keyboard(for: "/status"),
            allowed: { [weak self] in self?.generation == generation })
        } catch {
          if self.generation == generation { self.status = "任务提交失败，且无法发送通知。" }
        }
      }
    }
  }

  static func usageMessage(
    accounts: [CodexAccountStatus], gemini: GeminiUsageStatus?, updatedAt: Date?, now: Date = .now
  ) -> String {
    guard !accounts.isEmpty || gemini?.isConfigured == true else {
      return "暂无账户额度数据。请在 Mac 上安装并启用 account-usage 扩展，等待额度同步后再试。"
    }
    func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let currentYear = Calendar.current.component(.year, from: now)
    func shortDate(_ date: Date) -> String {
      formatter.dateFormat = Calendar.current.component(.year, from: date) == currentYear
        ? "MM/dd HH:mm" : "yy/MM/dd HH:mm"
      return formatter.string(from: date)
    }
    func resetCountdown(_ date: Date) -> String {
      let interval = date.timeIntervalSince(now)
      guard interval > 0 else { return "已到刷新时间" }
      let minutes = Int(ceil(interval / 60))
      let days = minutes / 1_440
      let hours = minutes % 1_440 / 60
      let remainder = minutes % 60
      var parts: [String] = []
      if days > 0 { parts.append("\(days)天") }
      if hours > 0 { parts.append("\(hours)小时") }
      if remainder > 0 { parts.append("\(remainder)分钟") }
      return parts.joined() + "后刷新"
    }
    func quotaLine(_ label: String, _ remaining: Double, _ resetAt: Date?) -> String {
      "  \(label)  \(percent(remaining))\(resetAt.map { " → \(resetCountdown($0))" } ?? "")"
    }
    func geminiLabel(_ window: String?) -> String {
      guard let window else { return "额度" }
      if window.localizedCaseInsensitiveContains("5h")
        || window.localizedCaseInsensitiveContains("five hour") { return "5h" }
      if window.localizedCaseInsensitiveContains("7d")
        || window.localizedCaseInsensitiveContains("week") { return "7d" }
      return "额度"
    }
    var lines = ["📊 账户额度 · 剩余"]
    for account in accounts {
      lines.append("\n\(account.isActive ? "●" : "○") Codex \(account.name)\(account.isDefault ? " · 默认" : "")")
      if let error = account.error { lines.append("  ⚠️ \(error)") }
      else if account.isHidden { lines.append("  额度已隐藏") }
      else {
        if let window = account.primary {
          let label = window.windowSeconds.map { $0 <= 21_600 ? "\(Int(($0 / 3_600).rounded()))h" : "7d" } ?? "额度"
          lines.append(quotaLine(label, window.remainingPercent, window.resetAt))
        }
        if let window = account.secondary {
          lines.append(quotaLine("7d", window.remainingPercent, window.resetAt))
        }
        if account.primary == nil && account.secondary == nil { lines.append("  暂无额度数据") }
      }
      if let credits = account.resetCredits {
        lines.append("  重置机会 ×\(credits.availableCount)")
      }
    }
    if let gemini, gemini.isConfigured {
      lines.append("\n\(gemini.isActive ? "●" : "○") Gemini")
      if let error = gemini.error { lines.append("  ⚠️ \(error)") }
      else if gemini.quotas.isEmpty { lines.append("  暂无额度数据") }
      else {
        for quota in gemini.quotas {
          lines.append(quotaLine(geminiLabel(quota.window), quota.remainingPercent, quota.resetAt))
        }
      }
    }
    if let updatedAt { lines.append("\n更新 \(shortDate(updatedAt))") }
    return lines.joined(separator: "\n")
  }

  static func latestReply(in messages: [ChatEntry], excluding existing: Set<String>) -> String? {
    messages.last { !existing.contains($0.id) && $0.kind == .assistant
      && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
  }

  static func statusMessage(
    project: String, session: String, sessionPath: String = "", firstPrompt: String? = nil,
    connection: ConnectionState, busy: Bool, loading: Bool, detail: String,
    model: String = "", thinking: String = "", contextPercent: Double? = nil,
    account: String? = nil
  ) -> String {
    let state: String
    switch connection {
    case .connected: state = loading ? "⏳ 正在加载配置" : (busy ? "⚡ 正在执行" : "✅ 就绪，可以发送任务")
    case .connecting: state = "⏳ 正在连接"
    case .disconnected: state = "⚪ 未连接"
    case .failed(let reason): state = "🔴 连接失败：\(reason)"
    }
    let prompt = firstPrompt?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
    let title = !session.isEmpty ? session
      : !prompt.isEmpty ? String(prompt.prefix(50))
      : sessionPath.isEmpty || (connection == .connected && !loading) ? "新会话"
      : "会话"
    // A session's file name is stable across restarts. Show its suffix so two untitled
    // conversations with similar first prompts are still distinguishable.
    let fileID = String(URL(fileURLWithPath: sessionPath).deletingPathExtension().lastPathComponent.suffix(12))
    let sessionLabel = sessionPath.isEmpty ? (connection == .connected ? title : "待连接")
      : "\(title) · #\(fileID)"
    let contextLabel = contextPercent.flatMap { percent in
      percent.isFinite ? String(format: "%.0f%%", percent) : nil
    } ?? "待统计"
    var lines = ["📍 Telegram 会话", "", "📁 项目  \(project)",
                 "💬 会话  \(sessionLabel)",
                 "🤖 模型  \(model.isEmpty ? "待加载" : model)",
                 "🧠 推理强度  \(model.isEmpty ? "待加载" : thinking)",
                 "👤 Codex 账户  \(account ?? "待同步")",
                 "📊 上下文  \(contextLabel)",
                 state]
    let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    if !detail.isEmpty { lines.append("\nℹ️ \(detail)") }
    return lines.joined(separator: "\n")
  }

  private static let maxImageBytes = 20 * 1_024 * 1_024

  private struct TelegramFile: Decodable {
    let filePath: String?
    enum CodingKeys: String, CodingKey { case filePath = "file_path" }
  }

  private static func downloadPhoto(_ photo: TelegramUpdate.Photo, token: String) async throws
    -> PromptAttachment
  {
    let file: TelegramFile = try await call(
      token: token, method: "getFile", body: ["file_id": photo.fileID])
    guard let path = file.filePath else { throw APIError.failed }
    let components = path.split(separator: "/").map(String.init)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }),
      let base = URL(string: "https://api.telegram.org/file/bot\(token)/")
    else { throw APIError.failed }
    let url = components.reduce(base) { $0.appendingPathComponent($1) }
    var request = URLRequest(url: url)
    request.timeoutInterval = 35
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      !data.isEmpty, data.count <= maxImageBytes else { throw APIError.failed }
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("pi-telegram-\(UUID().uuidString).jpg")
    try data.write(to: destination, options: .atomic)
    return PromptAttachment(url: destination, mimeType: "image/jpeg")
  }

  static func chunks(_ text: String, limit: Int = 3500) -> [String] {
    // Telegram limits message length; count UTF-16 units conservatively, preserving scalars.
    var result: [String] = []
    var chunk = ""
    var count = 0
    for scalar in text.unicodeScalars {
      let size = scalar.value > 0xFFFF ? 2 : 1
      if count + size > limit {
        result.append(chunk)
        chunk = ""
        count = 0
      }
      chunk.unicodeScalars.append(scalar)
      count += size
    }
    if !chunk.isEmpty { result.append(chunk) }
    return result
  }

  private static func send(
    _ text: String, token: String, userID: Int64,
    keyboard: [[[String: String]]]? = nil, allowed: () -> Bool = { true }
  ) async throws {
    let pieces = chunks(text.isEmpty ? "（空回复）" : text)
    for (index, chunk) in pieces.enumerated() {
      try Task.checkCancellation()
      guard allowed() else { throw CancellationError() }
      var body: [String: Any] = [
        "chat_id": userID, "text": TelegramMarkdown.html(chunk), "parse_mode": "HTML"
      ]
      if index == pieces.count - 1, let keyboard {
        body["reply_markup"] = ["inline_keyboard": keyboard]
      }
      let _: SentMessage = try await call(token: token, method: "sendMessage", body: body)
    }
  }
  private struct SentMessage: Decodable {
    let messageID: Int64
    enum CodingKeys: String, CodingKey { case messageID = "message_id" }
  }
  private struct Envelope<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
  }
  private enum APIError: Error { case failed }

  private static func call<T: Decodable>(token: String, method: String, body: [String: Any])
    async throws -> T
  {
    guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
      throw APIError.failed
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 35
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.failed }
    let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
    guard envelope.ok, let result = envelope.result else { throw APIError.failed }
    return result
  }
}

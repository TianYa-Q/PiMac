import Combine
import CryptoKit
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
    let messageID: Int64?
    let replyToMessage: RepliedMessage?
    let date: TimeInterval
    let from: Sender?
    let chat: Chat
    let text: String?
    let caption: String?
    let photo: [Photo]?
    let document: Document?

    enum CodingKeys: String, CodingKey {
      case messageID = "message_id", replyToMessage = "reply_to_message"
      case date, from, chat, text, caption, photo, document
    }
  }
  struct RepliedMessage: Decodable {
    let messageID: Int64
    enum CodingKeys: String, CodingKey { case messageID = "message_id" }
  }
  struct Document: Decodable {
    let fileID: String
    let fileSize: Int?
    let fileName: String?

    enum CodingKeys: String, CodingKey {
      case fileID = "file_id"
      case fileSize = "file_size"
      case fileName = "file_name"
    }
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
    let messageID: Int64?

    enum CodingKeys: String, CodingKey {
      case chat
      case messageID = "message_id"
    }
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

  func authorizedCallback(userID: Int64) -> (id: String, command: String, messageID: Int64?)? {
    guard let callbackQuery, callbackQuery.from.id == userID,
      !callbackQuery.from.isBot, callbackQuery.message?.chat.id == userID,
      callbackQuery.message?.chat.type == "private", let data = callbackQuery.data,
      Self.isAllowedCommand(data)
    else { return nil }
    return (callbackQuery.id, data, callbackQuery.message?.messageID)
  }

  private static func isAllowedCommand(_ data: String) -> Bool {
    if ["/sessions", "/projects", "/status", "/usage", "/accounts", "/new", "/compact", "/stop", "/help", "/model", "/thinking"].contains(data) {
      return true
    }
    if data.hasPrefix("session:") {
      let identifier = data.dropFirst(8)
      return identifier.count == 32 && identifier.allSatisfy { $0.isHexDigit && $0.isASCII }
    }
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

struct TelegramMessageSessionStore {
  struct Location: Codable, Equatable {
    let project: String
    let sessionPath: String
  }

  private(set) var entries: [Int64: Location] = [:]
  private static let key = "telegram.messageSessions"
  private static let limit = 2_000

  init(defaults: UserDefaults = .standard) {
    if let data = defaults.data(forKey: Self.key),
      let saved = try? JSONDecoder().decode([Int64: Location].self, from: data) {
      entries = saved
    }
  }

  subscript(messageID: Int64) -> Location? { entries[messageID] }

  mutating func remember(_ messageID: Int64, location: Location,
    defaults: UserDefaults = .standard, maxCount: Int = limit) {
    guard maxCount > 0 else { return }
    if entries.count >= maxCount && entries[messageID] == nil {
      // Telegram IDs increase within a private chat; keep the newest references.
      for id in entries.keys.sorted().prefix(entries.count - maxCount + 1) {
        entries.removeValue(forKey: id)
      }
    }
    entries[messageID] = location
    save(defaults: defaults)
  }

  mutating func clear(defaults: UserDefaults = .standard) {
    entries.removeAll()
    defaults.removeObject(forKey: Self.key)
  }

  private func save(defaults: UserDefaults) {
    guard let data = try? JSONEncoder().encode(entries) else { return }
    defaults.set(data, forKey: Self.key)
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
  private var retryTask: Task<Void, Never>?
  private var remoteModels: [String: AppModel] = [:]
  private var replyModels: [String: AppModel] = [:]
  private var messageSessions = TelegramMessageSessionStore()
  private var acknowledgementIDs: [Int64: Int64] = [:]
  private var sessionButtons: [[[String: String]]] = []
  // Only command cards sent during this run may be edited; old/unknown messages
  // (including agent replies with legacy keyboards) must remain untouched.
  private var editableCards: Set<Int64> = []
  private let projectKey = "telegram.projectPath"
  private let sessionsKey = "telegram.sessionPaths"
  private let activeReplyKey = "telegram.activeReplySession"
  private var activeReplyLocation: TelegramMessageSessionStore.Location? {
    get {
      guard let data = defaults.data(forKey: activeReplyKey) else { return nil }
      return try? JSONDecoder().decode(TelegramMessageSessionStore.Location.self, from: data)
    }
    set {
      defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: activeReplyKey)
    }
  }
  private var replies: [UUID: AnyCancellable] = [:]
  private var sessionPathObservations: [UUID: AnyCancellable] = [:]
  private var progressTasks: [UUID: Task<Void, Never>] = [:]
  private var progressCards: [UUID: Int64] = [:]
  private var pendingModels: Set<ObjectIdentifier> = []
  private struct RemotePrompt {
    let id = UUID()
    let text: String
    let attachments: [PromptAttachment]
    let token: String
    let userID: Int64
    let generation: UUID
    let messageID: Int64?
  }
  private var promptQueues: [ObjectIdentifier: TelegramPromptQueue<RemotePrompt>] = [:]
  private var queueObservations: [ObjectIdentifier: AnyCancellable] = [:]
  private var lastQueueDiagnostic: [ObjectIdentifier: (reason: String, date: Date)] = [:]
  private struct ConnectionRetry {
    let token: UUID
    let task: Task<Void, Never>
  }
  private var connectionRetries: [ObjectIdentifier: ConnectionRetry] = [:]
  private var sendingReplies = 0
  private var unsentReplies = TelegramUnsentReplyStore.load()
  private var pendingNotices = TelegramPendingNoticeStore.load()
  private var pendingFiles = TelegramPendingFileStore.load()
  private var generation = UUID()
  private let defaults = UserDefaults.standard
  static let allowedUpdates = ["message", "callback_query"]

  var enabled: Bool { defaults.bool(forKey: "telegram.enabled") }
  var userID: String { defaults.string(forKey: "telegram.userID") ?? "" }

  var canRestartSafely: Bool {
    pendingModels.isEmpty && replies.isEmpty && sendingReplies == 0 && promptQueues.values.allSatisfy(\.isEmpty)
      && (Array(remoteModels.values) + Array(replyModels.values)).allSatisfy { model in
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
    if token != TelegramTokenStore.load() || userID != self.userID {
      unsentReplies.removeAll()
      TelegramUnsentReplyStore.save(unsentReplies, defaults: defaults)
      pendingNotices.removeAll()
      TelegramPendingNoticeStore.save(pendingNotices, defaults: defaults)
      pendingFiles.removeAll()
      TelegramPendingFileStore.save(pendingFiles, defaults: defaults)
      TelegramUpdateCursorStore.clear(defaults: defaults)
      messageSessions.clear(defaults: defaults)
      activeReplyLocation = nil
      acknowledgementIDs.removeAll()
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
    retryTask?.cancel()
    retryTask = nil
    replies.removeAll()
    sessionPathObservations.removeAll()
    for progress in progressTasks.values { progress.cancel() }
    progressTasks.removeAll()
    progressCards.removeAll()
    editableCards.removeAll()
    acknowledgementIDs.removeAll()
    pendingModels.removeAll()
    queueObservations.removeAll()
    lastQueueDiagnostic.removeAll()
    for retry in connectionRetries.values { retry.task.cancel() }
    connectionRetries.removeAll()
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
    for model in replyModels.values { model.disconnect() }
    replyModels.removeAll()
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
    let since = TelegramUpdateCursorStore.earliestMessageDate(now: Date(), defaults: defaults)
    let generation = generation
    scheduleReplyRetry(token: token, userID: id, generation: generation)
    task = Task { [weak self] in
      var offset = TelegramUpdateCursorStore.load() ?? 0
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
          // An empty first poll still establishes the initial cursor, so messages
          // arriving while the app is closed after this point are not age-filtered.
          if TelegramUpdateCursorStore.load() == nil {
            TelegramUpdateCursorStore.save(offset)
          }
          for update in updates {
            guard !Task.isCancelled, self?.generation == generation else { break }
            guard update.updateID >= offset, update.updateID < Int64.max else { continue }
            // Checkpoint before dispatch: network errors or restarts must not run
            // an already accepted prompt a second time.
            offset = update.updateID + 1
            TelegramUpdateCursorStore.save(offset)
            guard let self else { continue }
            if let callback = update.authorizedCallback(userID: id) {
              // A failed callback acknowledgement must not replay its command.
              let _: Bool? = try? await Self.call(
                token: token, method: "answerCallbackQuery", body: ["callback_query_id": callback.id])
              guard self.generation == generation, !Task.isCancelled else { break }
              let reply = await self.handle(callback.command, token: token, userID: id, generation: generation, fromCallback: true)
              guard self.generation == generation, !Task.isCancelled else { break }
              let keyboard = self.keyboard(for: callback.command)
              if let messageID = callback.messageID,
                Self.shouldEditCallback(messageID: messageID, knownCards: self.editableCards,
                  command: callback.command) {
                await self.deliverNotice(
                  reply, token: token, userID: id, generation: generation,
                  keyboard: keyboard, editMessageID: messageID)
              } else {
                await self.deliverNotice(
                  reply, token: token, userID: id, generation: generation, keyboard: keyboard)
              }
            } else if let message = update.authorizedMessage(userID: id, since: since) {
              if let photo = message.photo?.last {
                let reply = await self.handleAttachment(
                  size: photo.fileSize, kind: "图片", caption: message.caption ?? "",
                  token: token, userID: id, generation: generation,
                  messageID: message.messageID, replyToID: message.replyToMessage?.messageID,
                  download: { try await Self.downloadPhoto(photo, token: token) })
                guard self.generation == generation, !Task.isCancelled else { break }
                await self.deliverNotice(reply, token: token, userID: id, generation: generation,
                  sourceMessageID: message.messageID)
              } else if let document = message.document {
                let reply = await self.handleAttachment(
                  size: document.fileSize, kind: "文件", caption: message.caption ?? "",
                  token: token, userID: id, generation: generation,
                  messageID: message.messageID, replyToID: message.replyToMessage?.messageID,
                  download: { try await Self.downloadDocument(document, token: token) })
                guard self.generation == generation, !Task.isCancelled else { break }
                await self.deliverNotice(reply, token: token, userID: id, generation: generation,
                  sourceMessageID: message.messageID)
              } else if let text = message.text {
                let reply = await self.handle(text, token: token, userID: id, generation: generation,
                  messageID: message.messageID, replyToID: message.replyToMessage?.messageID)
                guard self.generation == generation, !Task.isCancelled else { break }
                let keyboard = self.keyboard(for: text)
                await self.deliverNotice(
                  reply, token: token, userID: id, generation: generation, keyboard: keyboard,
                  sourceMessageID: message.messageID)
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

  private func handleAttachment(
    size: Int?, kind: String, caption: String, token: String, userID: Int64,
    generation: UUID, messageID: Int64?, replyToID: Int64?,
    download: () async throws -> PromptAttachment
  ) async -> String {
    if let size, size > Self.maxFileBytes {
      return "\(kind)过大，请发送不超过 20 MB 的\(kind)。"
    }
    do {
      let attachment = try await download()
      guard self.generation == generation, !Task.isCancelled else {
        try? FileManager.default.removeItem(at: attachment.url)
        return ""
      }
      return await handle(caption, attachments: [attachment], token: token,
        userID: userID, generation: generation, messageID: messageID, replyToID: replyToID)
    } catch {
      return "\(kind)下载失败或超过 20 MB，请稍后重试。"
    }
  }

  nonisolated static func shouldEditCallback(messageID: Int64, knownCards: Set<Int64>, command: String) -> Bool {
    knownCards.contains(messageID)
  }

  private func rememberCard(_ messageID: Int64) {
    if editableCards.count >= 500 { editableCards.removeAll() }
    editableCards.insert(messageID)
  }

  static let botCommands: [[String: String]] = [
    ["command": "projects", "description": "查看项目列表"],
    ["command": "sessions", "description": "切换会话"],
    ["command": "status", "description": "查看 Telegram 会话状态"],
    ["command": "model", "description": "选择 Telegram 模型"],
    ["command": "thinking", "description": "选择 Telegram 推理强度"],
    ["command": "usage", "description": "查看额度及切换 Codex 账户"],
    ["command": "accounts", "description": "查看额度并切换 Codex 账户"],
    ["command": "new", "description": "新建 Telegram 会话"],
    ["command": "compact", "description": "压缩 Telegram 会话上下文"],
    ["command": "stop", "description": "停止当前任务"],
    ["command": "help", "description": "查看帮助"],
  ]

  static let help = """
    Pi Mac · Telegram 远程控制
    项目选择和会话与桌面独立。先用 /projects 下方的按钮选项目，随后会自动显示会话状态；直接发送文本、照片或文件（可附说明）即可执行任务。正在执行的消息会依次排队，前一条完成后再处理下一条。

    📁 项目与会话
    /projects  选择项目
    /sessions  切换当前项目的会话
    回复先前的任务消息或 Bot 回复，可继续该消息对应的项目和会话，不改变当前项目选择。
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
    回传失败的回复会在后台自动重试，重启后也会继续。
    /help  查看本帮助

    会话未就绪时任务会排队并自动重试连接；/stop 可取消排队。
    生成的项目内文件可作为附件回传（每次最多 3 个，每个不超过 20 MB）。
    也可点击下方按钮操作。扩展确认仍需在 Mac 上完成。
    """

  private func keyboard(for text: String) -> [[[String: String]]]? {
    let command = text.split(maxSplits: 1, whereSeparator: \.isWhitespace).first
      .map { String($0).components(separatedBy: "@")[0].lowercased() } ?? ""
    guard ["/sessions", "/start", "/help", "/projects", "/status", "/usage", "/accounts", "/new", "/compact", "/stop", "/model", "/thinking"]
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
      [button("❔ 帮助", "/help")],
    ]
    return rows
  }

  static func projectList(_ projects: ArraySlice<WorkspaceProject>, start: Int) -> String {
    projects.enumerated().map { "\(start + $0.offset + 1). \($0.element.name)" }.joined(separator: "\n")
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
    if let sessionPath, let existing = replyModels.removeValue(forKey: sessionPath) {
      remoteModels[project.id] = existing
      return existing
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

  static func routeLocation(replyToID: Int64?,
    sessions: TelegramMessageSessionStore, active: TelegramMessageSessionStore.Location?
  ) -> TelegramMessageSessionStore.Location? {
    if let replyToID { return sessions[replyToID] }
    return active
  }

  private func activeModel(in workspace: WorkspaceModel) async -> AppModel? {
    if let location = activeReplyLocation { return await replyModel(for: location, in: workspace) }
    return remoteModel(in: workspace)
  }

  private func replyModel(for location: TelegramMessageSessionStore.Location,
    in workspace: WorkspaceModel) async -> AppModel? {
    guard let project = workspace.projects.first(where: { $0.id == location.project }),
      FileManager.default.fileExists(atPath: location.sessionPath)
    else { return nil }
    // Never open an arbitrary path from persisted metadata: verify the JSONL header and project.
    let valid = await Task.detached(priority: .utility) {
      AppModel.sessionExists(at: location.sessionPath, for: project.id)
    }.value
    guard valid else { return nil }
    if let primary = remoteModels[project.id], primary.currentSessionPath == location.sessionPath {
      return primary
    }
    if let existing = replyModels[location.sessionPath] {
      if !existing.isProcessRunning, case .disconnected = existing.connectionState {
        existing.resumeProcess(sessionPath: location.sessionPath, continueLastSession: false)
      }
      return existing
    }
    let model = AppModel(
      startupProjectURL: project.url, continueLastSession: false,
      startupSessionPath: location.sessionPath, restoreLastProjectOnLaunch: false,
      remembersDesktopProject: false,
      modelPreferenceKey: "telegram.selectedModelID",
      thinkingPreferenceKey: "telegram.thinkingLevels")
    model.extensionUI = workspace.extensionUI
    replyModels[location.sessionPath] = model
    return model
  }

  private func associate(_ messageID: Int64?, with model: AppModel?, sessionPath: String? = nil) {
    guard let messageID, let model, let project = model.projectURL?.standardizedFileURL.path
    else { return }
    let path = sessionPath ?? model.currentSessionPath
    guard !path.isEmpty else { return }
    let location = TelegramMessageSessionStore.Location(project: project, sessionPath: path)
    messageSessions.remember(messageID, location: location, defaults: defaults)
    if let acknowledgement = acknowledgementIDs.removeValue(forKey: messageID) {
      messageSessions.remember(acknowledgement, location: location, defaults: defaults)
    }
  }

  private func rememberAcknowledgement(_ cardID: Int64?, for sourceMessageID: Int64?) {
    guard let sourceMessageID, let cardID else { return }
    if let location = messageSessions[sourceMessageID] {
      messageSessions.remember(cardID, location: location, defaults: defaults)
    } else {
      if acknowledgementIDs.count >= 500 { acknowledgementIDs.removeAll() }
      acknowledgementIDs[sourceMessageID] = cardID
    }
  }

  private static let sessionPageSize = 5

  private func sessionsMessage(page: Int, project: WorkspaceProject, model: AppModel,
    sessions: [SessionItem]) -> String {
    sessionButtons.removeAll()
    let entries = Self.sessionChoices(sessions, currentPath: model.currentSessionPath,
      currentTitle: Self.sessionListTitle(name: model.sessionName,
        firstPrompt: model.messages.first(where: { $0.kind == .user })?.text))
    guard !entries.isEmpty else { return "当前项目暂无历史会话。发送消息或使用 /new 开始。" }
    let pageCount = (entries.count + Self.sessionPageSize - 1) / Self.sessionPageSize
    let page = min(max(1, page), pageCount)
    let start = (page - 1) * Self.sessionPageSize
    var lines = ["🗂 \(project.name) · 会话 \(page)/\(pageCount)"]
    for (index, entry) in entries.dropFirst(start).prefix(Self.sessionPageSize).enumerated() {
      let current = entry.path == model.currentSessionPath
      let title = Self.sessionListTitle(name: entry.title, firstPrompt: nil)
      lines.append("\(start + index + 1). \(current ? "✓ 当前 · " : "")\(title)")
      let token = Self.sessionIdentifier(project: project.id, path: entry.path)
      sessionButtons.append([["text": "\(current ? "✓ " : "")\(start + index + 1). \(String(title.prefix(20)))",
        "callback_data": "session:\(token)"]])
    }
    var navigation: [[String: String]] = []
    if page > 1 { navigation.append(["text": "⬅️ 上一页", "callback_data": "/sessions \(page - 1)"]) }
    if start + Self.sessionPageSize < entries.count {
      navigation.append(["text": "下一页 ➡️", "callback_data": "/sessions \(page + 1)"])
    }
    if !navigation.isEmpty { sessionButtons.append(navigation) }
    lines.append("点击按钮切换当前项目的会话；也可以直接回复之前的任务消息或 Bot 回复，继续对应会话。切换前请等待当前任务及排队消息完成。")
    return lines.joined(separator: "\n")
  }

  nonisolated static func sessionIdentifier(project: String, path: String) -> String {
    let digest = SHA256.hash(data: Data("\(project)\u{0}\(path)".utf8))
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  nonisolated static func sessionForIdentifier(_ identifier: String, project: String,
    sessions: [SessionItem]) -> SessionItem? {
    sessions.first { sessionIdentifier(project: project, path: $0.path) == identifier }
  }

  nonisolated static func sessionChoices(_ sessions: [SessionItem], currentPath: String,
    currentTitle: String) -> [SessionItem] {
    var seen = Set<String>()
    var choices = sessions.filter { seen.insert($0.path).inserted }
    if !currentPath.isEmpty, seen.insert(currentPath).inserted {
      choices.insert(SessionItem(path: currentPath, title: currentTitle, modifiedAt: .now), at: 0)
    }
    return choices
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

  private func deliverNotice(
    _ text: String, token: String, userID: Int64, generation: UUID,
    keyboard: [[[String: String]]]? = nil, editMessageID: Int64? = nil,
    sourceMessageID: Int64? = nil
  ) async {
    guard self.generation == generation, !Task.isCancelled else { return }
    sendingReplies += 1
    defer { sendingReplies -= 1 }
    do {
      let cardID: Int64?
      if let editMessageID {
        cardID = try await Self.editOrSend(
          text, token: token, userID: userID, messageID: editMessageID, keyboard: keyboard)
      } else {
        cardID = try await Self.send(text, token: token, userID: userID, keyboard: keyboard)
      }
      guard self.generation == generation else { return }
      if keyboard != nil, let cardID { rememberCard(cardID) }
      rememberAcknowledgement(cardID, for: sourceMessageID)
    } catch {
      guard self.generation == generation, !Task.isCancelled else { return }
      pendingNotices.append(TelegramPendingNotice(
        id: UUID(), text: text, keyboard: keyboard, sourceMessageID: sourceMessageID))
      TelegramPendingNoticeStore.save(pendingNotices, defaults: defaults)
      status = "Telegram 消息发送失败，正在后台重试。"
      scheduleReplyRetry(token: token, userID: userID, generation: generation)
    }
  }

  private func scheduleReplyRetry(token: String, userID: Int64, generation: UUID) {
    guard retryTask == nil, !pendingNotices.isEmpty || !unsentReplies.isEmpty || !pendingFiles.isEmpty else { return }
    retryTask = Task { [weak self] in
      guard let self else { return }
      while self.generation == generation && !Task.isCancelled {
        let notices = self.pendingNotices
        let replies = self.unsentReplies.keys.sorted().flatMap { project in
          (self.unsentReplies[project] ?? []).map { (project, $0) }
        }
        let files = self.pendingFiles
        guard !notices.isEmpty || !replies.isEmpty || !files.isEmpty else { break }
        var failed = false
        var replyFailed = false
        for notice in notices {
          guard self.generation == generation, !Task.isCancelled else { break }
          self.sendingReplies += 1
          let delivered: Bool
          do {
            let cardID = try await Self.send(
              notice.text, token: token, userID: userID, keyboard: notice.keyboard,
              allowed: { [weak self] in self?.generation == generation })
            if self.generation == generation, let cardID {
              if notice.keyboard != nil { self.rememberCard(cardID) }
              self.rememberAcknowledgement(cardID, for: notice.sourceMessageID)
            }
            delivered = true
          } catch {
            delivered = false
          }
          self.sendingReplies -= 1
          guard self.generation == generation, !Task.isCancelled else { break }
          if delivered {
            self.pendingNotices.removeAll { $0.id == notice.id }
            TelegramPendingNoticeStore.save(self.pendingNotices, defaults: self.defaults)
          } else { failed = true }
        }
        for (project, reply) in replies {
          guard self.generation == generation, !Task.isCancelled else { break }
          TelegramDeliveryLog.record("retry_started", task: reply.id,
            sessionPath: reply.sessionPath)
          self.sendingReplies += 1
          let delivered: Bool
          do {
            try await Self.send(reply.text, token: token, userID: userID,
              allowed: { [weak self] in self?.generation == generation },
              onSent: { [weak self] id in
                guard let self, self.generation == generation, !reply.sessionPath.isEmpty else { return }
                self.messageSessions.remember(id, location: .init(
                  project: project, sessionPath: reply.sessionPath), defaults: self.defaults)
              })
            delivered = true
            TelegramDeliveryLog.record("retry_succeeded", task: reply.id,
              sessionPath: reply.sessionPath)
          } catch {
            delivered = false
            TelegramDeliveryLog.record("retry_failed", task: reply.id,
              sessionPath: reply.sessionPath, details: "errorType=\(String(describing: type(of: error)))")
          }
          self.sendingReplies -= 1
          guard self.generation == generation, !Task.isCancelled else { break }
          if delivered {
            self.unsentReplies[project]?.removeAll { $0.id == reply.id }
            if self.unsentReplies[project]?.isEmpty == true { self.unsentReplies.removeValue(forKey: project) }
            TelegramUnsentReplyStore.save(self.unsentReplies, defaults: self.defaults)
          } else {
            failed = true
            replyFailed = true
          }
        }
        // Do not deliver attachments before their accompanying text has reached
        // Telegram. Retry all failed text replies before attempting files.
        if replyFailed {
          try? await Task.sleep(for: .seconds(5))
          continue
        }
        for file in files {
          guard self.generation == generation, !Task.isCancelled else { break }
          self.sendingReplies += 1
          let delivered: Bool
          do {
            let url = try Self.validOutputFile(file.filePath, projectPath: file.projectPath)
            try await Self.sendDocument(url, token: token, userID: userID,
              allowed: { [weak self] in self?.generation == generation })
            delivered = true
          } catch FileDeliveryError.invalid {
            // A file removed or moved outside the project cannot be retried.
            self.pendingFiles.removeAll { $0.id == file.id }
            TelegramPendingFileStore.save(self.pendingFiles, defaults: self.defaults)
            await self.deliverNotice(
              "⚠️ 待发送的附件已不存在或不符合文件限制，已取消发送。",
              token: token, userID: userID, generation: generation)
            delivered = true
          } catch {
            delivered = false
          }
          self.sendingReplies -= 1
          guard self.generation == generation, !Task.isCancelled else { break }
          if delivered {
            self.pendingFiles.removeAll { $0.id == file.id }
            TelegramPendingFileStore.save(self.pendingFiles, defaults: self.defaults)
          } else { failed = true }
        }
        if failed { try? await Task.sleep(for: .seconds(5)) }
      }
      if self.generation == generation { self.retryTask = nil }
    }
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
    generation: UUID, fromCallback: Bool = false,
    messageID: Int64? = nil, replyToID: Int64? = nil
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
      guard let model = await activeModel(in: workspace), let projectURL = model.projectURL,
        let project = workspace.projects.first(where: { $0.id == projectURL.standardizedFileURL.path })
      else { return "请先用 /projects 选择项目。" }
      let sessions = await Task.detached(priority: .utility) {
        AppModel.discoverSessions(for: project.id)
      }.value
      guard generation == self.generation, !Task.isCancelled else { return "连接已重置，请重新发送命令。" }
      return sessionsMessage(page: parts.count == 2 ? Int(parts[1]) ?? 1 : 1,
        project: project, model: model, sessions: sessions)
    case let action where action.hasPrefix("session:") && fromCallback:
      guard let model = await activeModel(in: workspace), let project = model.projectURL?.standardizedFileURL.path,
        workspace.projects.contains(where: { $0.id == project })
      else { return "请先用 /projects 选择项目。" }
      let identifier = String(action.dropFirst(8))
      if !model.currentSessionPath.isEmpty,
        Self.sessionIdentifier(project: project, path: model.currentSessionPath) == identifier {
        return "当前已在此会话。"
      }
      let sessions = await Task.detached(priority: .utility) {
        AppModel.discoverSessions(for: project)
      }.value
      guard generation == self.generation, !Task.isCancelled else { return "连接已重置，请重新发送命令。" }
      guard let target = Self.sessionForIdentifier(identifier, project: project, sessions: sessions)
      else { return "会话已不存在或不在当前项目，请用 /sessions 刷新。" }
      guard model.canReuseProcessForNewSession, model.canRestartSafely,
        promptQueues[ObjectIdentifier(model)]?.isEmpty != false,
        !pendingModels.contains(ObjectIdentifier(model)),
        !workspace.extensionUI.hasPendingRequests(from: model)
      else { return "当前有任务或会话未就绪，稍后再切换。" }
      if let other = replyModels[target.path] {
        guard other.canRestartSafely,
          promptQueues[ObjectIdentifier(other)]?.isEmpty != false,
          !pendingModels.contains(ObjectIdentifier(other)),
          !workspace.extensionUI.hasPendingRequests(from: other)
        else { return "此会话正在执行其他任务，请等待完成后再切换。" }
        other.disconnect()
        replyModels.removeValue(forKey: target.path)
      }
      var switched: Bool?
      model.switchSession(path: target.path) { switched = $0 }
      let deadline = Date().addingTimeInterval(20)
      while generation == self.generation && !Task.isCancelled && switched == nil && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard generation == self.generation, !Task.isCancelled else { return "连接已重置，请重新发送命令。" }
      guard switched == true else { return "切换会话失败或超时，请使用 /status 查看状态后重试。" }
      rememberSession(model)
      activeReplyLocation = .init(project: project, sessionPath: target.path)
      workspace.remoteSessionChanged(in: model.projectURL, sessionPath: model.currentSessionPath)
      return "已切换到「\(Self.sessionListTitle(name: target.title, firstPrompt: nil))」。"
    case "/projects":
      let page = parts.count == 2 ? min(max(1, Int(parts[1]) ?? 1), max(1, (workspace.projects.count + 29) / 30)) : 1
      let start = min((page - 1) * 30, workspace.projects.count)
      return workspace.projects.isEmpty
        ? "请先在 Mac 上添加项目。"
        : Self.projectList(workspace.projects.dropFirst(start).prefix(30), start: start)
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
      activeReplyLocation = nil
      guard let model = remoteModel(in: workspace) else { return "请先在 Mac 上添加项目。" }
      await Self.waitForSessionStatus(in: model)
      guard generation == self.generation, !Task.isCancelled else {
        return "连接已重置，请重新发送命令。"
      }
      return "Telegram 已选择 \(project.name)。\n\n" + sessionStatus(for: model)
    default: break
    }
    if command == "/usage" || command == "/accounts" {
      let model = remoteModel(in: workspace)
      let usage = workspace.extensionUI.usage(for: model)
      return Self.usageMessage(accounts: usage.accounts, gemini: usage.gemini, updatedAt: usage.updatedAt)
    }
    guard let model = await (replyToID == nil ? activeModel(in: workspace)
      : remoteModel(in: workspace)) else {
      return activeReplyLocation == nil ? "请先在 Mac 上添加项目。"
        : "上次引用的会话已不可用，请用 /projects 重新选择项目。"
    }
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
      let deadline = Date().addingTimeInterval(10)
      while generation == self.generation && !Task.isCancelled && Date() < deadline {
        if model.selectedModelId == choice.id { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard generation == self.generation, !Task.isCancelled else {
        return "连接已重置，请重新发送命令。"
      }
      return sessionStatus(for: model)
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
    case "/stop":
      let modelID = ObjectIdentifier(model)
      let cancelled = promptQueues.removeValue(forKey: modelID)?.items ?? []
      queueObservations.removeValue(forKey: modelID)
      connectionRetries.removeValue(forKey: modelID)?.task.cancel()
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
        if self.activeReplyLocation != nil, let project = model.projectURL?.standardizedFileURL.path,
          !model.currentSessionPath.isEmpty {
          let previous = self.activeReplyLocation?.sessionPath
          self.activeReplyLocation = .init(project: project, sessionPath: model.currentSessionPath)
          if let previous, self.replyModels[previous] === model {
            self.replyModels.removeValue(forKey: previous)
            self.replyModels[model.currentSessionPath] = model
          }
        }
        self.rememberSession(model)
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
      let targetModel: AppModel
      if let replyToID {
        guard let location = Self.routeLocation(replyToID: replyToID,
          sessions: messageSessions, active: activeReplyLocation) else {
          return "找不到所回复消息关联的会话，请用 /sessions 选择会话。"
        }
        guard let resolved = await replyModel(for: location, in: workspace),
          generation == self.generation, !Task.isCancelled else {
          return "原会话已不可用，请用 /sessions 重新选择。"
        }
        targetModel = resolved
        activeReplyLocation = location
      } else {
        targetModel = model
      }
      // Accept requests during startup and reconnect in the background. Never
      // force the user to resend a prompt solely because Pi is not yet ready.
      let prompt = RemotePrompt(
        text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? (attachments.first?.isImage == true ? "请分析这张图片。" : "请阅读并分析这个文件。") : text,
        attachments: attachments, token: token, userID: userID, generation: generation,
        messageID: messageID)
      let modelID = ObjectIdentifier(targetModel)
      if !canSubmitRemotePrompt(in: targetModel) || promptQueues[modelID]?.isEmpty == false {
        guard let position = promptQueues[modelID, default: .init()].append(prompt)
        else { return "等待队列已满，请稍后再试。" }
        associate(messageID, with: targetModel)
        TelegramDeliveryLog.record("prompt_queued", task: prompt.id,
          sessionPath: targetModel.currentSessionPath,
          details: "position=\(position) blockers=\(queueBlockers(for: targetModel))")
        observeQueue(in: targetModel)
        submittedAttachments = true
        startConnectionRetry(for: targetModel)
        // If the previous turn settled while this update was being handled, drain now.
        scheduleQueueDrain(for: targetModel)
        if !targetModel.clientConnectedForCommands || targetModel.isLoadingConfiguration {
          return "会话尚未就绪，任务已排队（第 \(position) 位），正在自动重试连接。就绪后会执行并回传回复。"
        }
        return "已排队（等待队列第 \(position) 位）。完成后会自动回传回复。"
      }
      submitRemotePrompt(prompt, in: targetModel)
      submittedAttachments = true
      let label = targetModel.projectURL?.lastPathComponent ?? "当前项目"
      return replyToID == nil ? "已发送到「\(label)」。" : "已发送到「\(label)」的原会话。"
    }
  }

  private func canSubmitRemotePrompt(in model: AppModel) -> Bool {
    model.clientConnectedForCommands && model.canRestartSafely
      && !pendingModels.contains(ObjectIdentifier(model))
      && workspace?.extensionUI.hasPendingRequests(from: model) == false
  }

  private func queueBlockers(for model: AppModel) -> String {
    var reasons: [String] = []
    if !model.clientConnectedForCommands { reasons.append("rpc_disconnected") }
    if model.isStreaming { reasons.append("streaming") }
    if model.isCompacting { reasons.append("compacting") }
    if model.isLoadingConfiguration { reasons.append("configuration_loading") }
    if !model.queuedPrompts.isEmpty { reasons.append("pi_queue") }
    if !model.canRestartSafely { reasons.append("not_restart_safe") }
    if pendingModels.contains(ObjectIdentifier(model)) { reasons.append("remote_task_pending") }
    if workspace?.extensionUI.hasPendingRequests(from: model) != false {
      reasons.append("extension_request")
    }
    return reasons.isEmpty ? "ready" : reasons.joined(separator: ",")
  }

  private func logQueueBlocker(for model: AppModel) {
    let id = ObjectIdentifier(model)
    guard let first = promptQueues[id]?.first else { return }
    let reason = queueBlockers(for: model)
    let now = Date()
    if let previous = lastQueueDiagnostic[id], previous.reason == reason,
      now.timeIntervalSince(previous.date) < 30 { return }
    lastQueueDiagnostic[id] = (reason, now)
    TelegramDeliveryLog.record("queue_waiting", task: first.id,
      sessionPath: model.currentSessionPath, details: "blockers=\(reason)")
  }

  static func shouldRetryConnection(
    _ state: ConnectionState, isLoading: Bool, canRestart: Bool
  ) -> Bool {
    guard !isLoading, canRestart else { return false }
    switch state {
    case .failed, .disconnected: return true
    case .connecting, .connected: return false
    }
  }

  private func startConnectionRetry(for model: AppModel) {
    let id = ObjectIdentifier(model)
    guard connectionRetries[id] == nil else { return }
    let token = UUID()
    let task = Task { @MainActor [weak self, weak model] in
      guard let self, let model else { return }
      while !Task.isCancelled, self.promptQueues[id]?.isEmpty == false {
        self.logQueueBlocker(for: model)
        self.retryConnectionIfNeeded(for: model)
        self.scheduleQueueDrain(for: model)
        try? await Task.sleep(for: .seconds(5))
      }
      if self.connectionRetries[id]?.token == token {
        self.connectionRetries.removeValue(forKey: id)
      }
    }
    connectionRetries[id] = ConnectionRetry(token: token, task: task)
  }

  private func retryConnectionIfNeeded(for model: AppModel) {
    let id = ObjectIdentifier(model)
    guard promptQueues[id]?.isEmpty == false,
      !pendingModels.contains(id),
      workspace?.extensionUI.hasPendingRequests(from: model) == false,
      Self.shouldRetryConnection(model.connectionState,
        isLoading: model.isLoadingConfiguration, canRestart: model.canRestartSafely)
    else { return }
    if let first = promptQueues[id]?.first {
      TelegramDeliveryLog.record("connection_retry", task: first.id,
        sessionPath: model.currentSessionPath)
    }
    if model.isProcessRunning { model.suspendProcess() }
    guard !model.isProcessRunning else { return }
    model.resumeProcess(
      sessionPath: model.currentSessionPath.isEmpty ? nil : model.currentSessionPath,
      continueLastSession: false)
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
      TelegramDeliveryLog.record("queue_drained", task: first.id,
        sessionPath: model.currentSessionPath)
      self.promptQueues[id]?.removeFirst()
      if self.promptQueues[id]?.isEmpty == true {
        self.promptQueues.removeValue(forKey: id)
        self.queueObservations.removeValue(forKey: id)
        self.lastQueueDiagnostic.removeValue(forKey: id)
        self.connectionRetries.removeValue(forKey: id)?.task.cancel()
      }
      self.submitRemotePrompt(first, in: model)
    }
  }

  private static func editProgress(
    _ text: String, token: String, userID: Int64, messageID: Int64
  ) async throws {
    let body: [String: Any] = [
      "chat_id": userID, "message_id": messageID,
      "text": TelegramMarkdown.html(text), "parse_mode": "HTML"
    ]
    do {
      let _: SentMessage = try await call(token: token, method: "editMessageText", body: body)
    } catch APIError.notModified {
      // Concurrent updates may produce the same text; no new message is needed.
    }
  }

  static func progressElapsed(startedAt: Date, now: Date = .now) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remainingSeconds = seconds % 60
    return hours > 0
      ? "\(hours) 小时 \(minutes) 分 \(remainingSeconds) 秒"
      : "\(minutes) 分 \(remainingSeconds) 秒"
  }

  private func progressStatus(for model: AppModel, startedAt: Date) -> String {
    sessionStatus(for: model) + "\n⏱ 已执行  \(Self.progressElapsed(startedAt: startedAt))"
  }

  private func startProgress(
    key: UUID, model: AppModel, token: String, userID: Int64, generation: UUID,
    startedAt: Date
  ) {
    guard progressTasks[key] == nil, replies[key] != nil else { return }
    progressTasks[key] = Task { @MainActor [weak self, weak model] in
      do { try await Task.sleep(for: .seconds(8)) } catch { return }
      guard let self, let model, self.generation == generation, self.replies[key] != nil,
        !Task.isCancelled else { return }
      let messageID: Int64?
      do {
        messageID = try await Self.send(
          self.progressStatus(for: model, startedAt: startedAt),
          token: token, userID: userID,
          allowed: { [weak self] in self?.generation == generation && self?.replies[key] != nil })
      } catch { return } // Progress is transient; do not persist or retry it.
      guard let messageID, self.generation == generation else { return }
      self.associate(messageID, with: model)
      if self.replies[key] == nil {
        // The task finished while the initial progress message was in flight.
        Task { try? await Self.editProgress(
          self.progressStatus(for: model, startedAt: startedAt) + "\n\n任务已结束，回复将单独发送。",
          token: token, userID: userID, messageID: messageID) }
        return
      }
      self.progressCards[key] = messageID
      while self.generation == generation && self.replies[key] != nil && !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(30)) } catch { break }
        guard self.generation == generation, self.replies[key] != nil, !Task.isCancelled else { break }
        try? await Self.editProgress(
          self.progressStatus(for: model, startedAt: startedAt),
          token: token, userID: userID, messageID: messageID)
      }
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
    let startedAt = Date()
    func log(_ event: String, _ details: String = "") {
      TelegramDeliveryLog.record(event, task: key, sessionPath: model.currentSessionPath,
        details: details)
    }
    log("submitted", "model=\(model.selectedModelId)")
    model.onTelegramLifecycleEvent = { [weak model] event in
      guard let model else { return }
      TelegramDeliveryLog.record(event, task: key, sessionPath: model.currentSessionPath)
    }
    sessionPathObservations[key] = model.$currentSessionPath
      .sink { [weak self, weak model] path in
        guard let self, let model, !path.isEmpty, self.generation == generation,
          self.pendingModels.contains(modelID) else { return }
        self.associate(prompt.messageID, with: model, sessionPath: path)
      }
    var started = false
    replies[key] = model.$isStreaming.sink { [weak self, weak model] streaming in
      if streaming {
        if !started { log("streaming_started") }
        started = true
        return
      }
      guard started else { return }
      log("streaming_stopped")
      Task { @MainActor [weak self, weak model] in
        guard let self, self.generation == generation, let model else { return }
        guard self.replies.removeValue(forKey: key) != nil else { return }
        model.onTelegramLifecycleEvent = nil
        self.progressTasks.removeValue(forKey: key)?.cancel()
        self.sessionPathObservations.removeValue(forKey: key)
        self.associate(prompt.messageID, with: model)
        if let project = model.projectURL?.standardizedFileURL.path,
          self.remoteModels[project] === model { self.rememberSession(model) }
        self.workspace?.remoteSessionChanged(
          in: model.projectURL, sessionPath: model.currentSessionPath)
        let output = Self.latestReply(in: model.messages, excluding: existing)
        let project = model.projectURL?.standardizedFileURL.path
        let textReply = output ?? "任务已结束，没有文本回复。"
        var text = textReply
        if let project {
          var files: [URL] = []
          for path in Self.outputFiles(in: textReply).prefix(30) {
            guard let url = try? Self.validOutputFile(path, projectPath: project,
              modifiedSince: startedAt), !files.contains(url) else { continue }
            files.append(url)
            if files.count > 3 { break }
          }
          if files.count > 3 {
            files.removeLast()
            text += "\n\n⚠️ 每次最多发送 3 个附件。"
          }
          if !files.isEmpty {
            self.pendingFiles += files.map { url in
              TelegramPendingFile(id: UUID(), projectPath: project, filePath: url.path)
            }
            TelegramPendingFileStore.save(self.pendingFiles, defaults: self.defaults)
            text += "\n\n📎 \(files.count) 个附件将单独发送。"
          }
        }
        // A newer successful response must not discard an older undelivered reply.
        self.sendingReplies += 1
        defer { self.sendingReplies -= 1 }
        var delivered = false
        log("send_started", "characters=\(text.count)")
        do {
          try await Self.send(
            text, token: token, userID: userID,
            allowed: { [weak self] in self?.generation == generation },
            onSent: { [weak self, weak model] id in self?.associate(id, with: model) })
          delivered = true
          log("send_succeeded")
        } catch {
          log("send_failed", "errorType=\(String(describing: type(of: error)))")
          if self.generation == generation {
            if let project {
              self.unsentReplies[project, default: []].append(TelegramUnsentReply(
                id: key, sessionPath: model.currentSessionPath,
                text: text))
              TelegramUnsentReplyStore.save(self.unsentReplies, defaults: self.defaults)
              log("reply_queued_for_retry")
              self.scheduleReplyRetry(token: token, userID: userID, generation: generation)
            }
            self.status = "回复发送失败，正在后台重试。"
          }
        }
        if let cardID = self.progressCards.removeValue(forKey: key), self.generation == generation {
          let state = delivered ? "✅ 回复已单独发送。" : "⚠️ 回复正在后台重试发送。"
          try? await Self.editProgress(self.progressStatus(for: model, startedAt: startedAt) + "\n\n" + state,
            token: token, userID: userID, messageID: cardID)
        }
        self.scheduleReplyRetry(token: token, userID: userID, generation: generation)
        self.pendingModels.remove(modelID)
        self.scheduleQueueDrain(for: model)
        // Historical reply tabs need no permanent RPC process while idle.
        if self.replyModels[model.currentSessionPath] === model,
          self.promptQueues[modelID]?.isEmpty != false,
          !self.pendingModels.contains(modelID),
          self.workspace?.extensionUI.hasPendingRequests(from: model) == false {
          model.suspendProcess()
        }
      }
    }
    model.sendRemotePrompt(prompt.text, attachments: attachments) {
      [weak self, weak model] accepted in
      if !accepted {
        for attachment in attachments { try? FileManager.default.removeItem(at: attachment.url) }
      }
      log(accepted ? "prompt_accepted" : "prompt_rejected")
      if accepted, let self, self.generation == generation, let model {
        self.associate(prompt.messageID, with: model)
        self.workspace?.remoteSessionChanged(
          in: model.projectURL, sessionPath: model.currentSessionPath)
        self.startProgress(key: key, model: model, token: token, userID: userID,
          generation: generation, startedAt: startedAt)
      }
      guard !accepted, let self, self.generation == generation,
        self.replies.removeValue(forKey: key) != nil
      else { return }
      model?.onTelegramLifecycleEvent = nil
      self.progressTasks.removeValue(forKey: key)?.cancel()
      self.progressCards.removeValue(forKey: key)
      self.sessionPathObservations.removeValue(forKey: key)
      self.pendingModels.remove(modelID)
      if let model { self.scheduleQueueDrain(for: model) }
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation else { return }
        await self.deliverNotice(
          "任务提交失败，请在 Mac 上查看错误并使用 /status 检查状态。",
          token: token, userID: userID, generation: generation,
          keyboard: self.keyboard(for: "/status"))
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

  /// Only an explicit Markdown file link is treated as a deliverable. Plain
  /// code references (including changed source files) must never be uploaded.
  nonisolated static func outputFiles(in text: String) -> [String] {
    let pattern = #"\[[^\]\r\n]+\]\(([^)\r\n]+)\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { match -> String? in
      guard let capture = Range(match.range(at: 1), in: text) else { return nil }
      let raw = String(text[capture]).trimmingCharacters(in: .whitespaces)
      if raw.hasPrefix("file://") {
        guard let url = URL(string: raw), url.isFileURL,
          url.host == nil || url.host == "" || url.host == "localhost"
        else { return nil }
        return url.path
      }
      guard !raw.contains("://"), !raw.hasPrefix("#"), !raw.hasPrefix("mailto:") else { return nil }
      return raw.removingPercentEncoding
    }
  }

  private enum FileDeliveryError: Error { case invalid }

  nonisolated static func validOutputFile(
    _ path: String, projectPath: String, modifiedSince: Date? = nil
  ) throws -> URL {
    guard !path.isEmpty, path.count <= 500, !path.contains("\n"), !path.contains("\r") else {
      throw FileDeliveryError.invalid
    }
    let root = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
    guard url.path.hasPrefix(root.path + "/"),
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
      values.isRegularFile == true, let size = values.fileSize, size <= 20 * 1_024 * 1_024
    else { throw FileDeliveryError.invalid }
    if let modifiedSince {
      guard let modified = values.contentModificationDate,
        modified >= modifiedSince.addingTimeInterval(-1)
      else { throw FileDeliveryError.invalid }
    }
    return url
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

  private static let maxFileBytes = 20 * 1_024 * 1_024

  private struct TelegramFile: Decodable {
    let filePath: String?
    enum CodingKeys: String, CodingKey { case filePath = "file_path" }
  }

  private static func downloadPhoto(_ photo: TelegramUpdate.Photo, token: String) async throws
    -> PromptAttachment
  {
    try await downloadFile(fileID: photo.fileID, token: token, localName: "photo.jpg", mimeType: "image/jpeg")
  }

  private static func downloadDocument(_ document: TelegramUpdate.Document, token: String) async throws
    -> PromptAttachment
  {
    try await downloadFile(fileID: document.fileID, token: token,
      localName: safeDocumentName(document.fileName), mimeType: nil)
  }

  /// Telegram filenames are untrusted; never use path separators or control characters
  /// when saving to the temporary directory or embedding the resulting path in a prompt.
  nonisolated static func safeDocumentName(_ fileName: String?) -> String {
    let name = (fileName ?? "file").split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? "file"
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    let safe = String(String.UnicodeScalarView(name.unicodeScalars.map {
      allowed.contains($0) ? $0 : "_"
    }))
    let ext = (safe as NSString).pathExtension
    let suffix = !ext.isEmpty && ext.count <= 12 && ext.allSatisfy(\.isASCII) ? ".\(ext)" : ""
    let base = suffix.isEmpty ? safe : String(safe.dropLast(suffix.count))
    let prefix = String(base.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return (prefix.isEmpty ? "file" : prefix) + suffix
  }

  private static func downloadFile(fileID: String, token: String, localName: String, mimeType: String?) async throws
    -> PromptAttachment
  {
    let file: TelegramFile = try await call(
      token: token, method: "getFile", body: ["file_id": fileID])
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
      !data.isEmpty, data.count <= maxFileBytes else { throw APIError.failed }
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("pi-telegram-\(UUID().uuidString)-\(localName)")
    try data.write(to: destination, options: .atomic)
    return PromptAttachment(url: destination, mimeType: mimeType)
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

  private static func sendDocument(
    _ url: URL, token: String, userID: Int64, allowed: () -> Bool
  ) async throws {
    try Task.checkCancellation()
    guard allowed(), let endpoint = URL(string: "https://api.telegram.org/bot\(token)/sendDocument")
    else { throw APIError.failed }
    guard let data = try? Data(contentsOf: url), data.count <= maxFileBytes
    else { throw FileDeliveryError.invalid }
    guard allowed() else { throw CancellationError() }
    let boundary = "PiMac-\(UUID().uuidString)"
    let name = safeDocumentName(url.lastPathComponent)
    var body = Data()
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n\(userID)\r\n".utf8))
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"document\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
    body.append(data)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 90
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    let (responseData, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let envelope = try? JSONDecoder().decode(Envelope<SentMessage>.self, from: responseData),
      envelope.ok, envelope.result != nil
    else { throw APIError.failed }
  }

  @discardableResult
  private static func send(
    _ text: String, token: String, userID: Int64,
    keyboard: [[[String: String]]]? = nil, allowed: () -> Bool = { true },
    onSent: ((Int64) -> Void)? = nil
  ) async throws -> Int64? {
    let pieces = chunks(text.isEmpty ? "（空回复）" : text)
    var lastID: Int64?
    for (index, chunk) in pieces.enumerated() {
      try Task.checkCancellation()
      guard allowed() else { throw CancellationError() }
      var body: [String: Any] = [
        "chat_id": userID, "text": TelegramMarkdown.html(chunk), "parse_mode": "HTML"
      ]
      if index == pieces.count - 1, let keyboard {
        body["reply_markup"] = ["inline_keyboard": keyboard]
      }
      let sent: SentMessage = try await call(token: token, method: "sendMessage", body: body)
      lastID = sent.messageID
      onSent?(sent.messageID)
    }
    return lastID
  }
  /// Update only a known command card; fall back to a new card if editing fails.
  private static func editOrSend(
    _ text: String, token: String, userID: Int64, messageID: Int64?,
    keyboard: [[[String: String]]]? = nil
  ) async throws -> Int64? {
    guard let messageID else {
      return try await send(text, token: token, userID: userID, keyboard: keyboard)
    }
    let pieces = chunks(text.isEmpty ? "（空回复）" : text)
    var body: [String: Any] = [
      "chat_id": userID, "message_id": messageID,
      "text": TelegramMarkdown.html(pieces[0]), "parse_mode": "HTML",
      "reply_markup": ["inline_keyboard": pieces.count == 1 ? (keyboard ?? []) : []]
    ]
    do {
      let _: SentMessage = try await call(token: token, method: "editMessageText", body: body)
    } catch APIError.notModified {
      // The card already shows the same content.
    } catch {
      return try await send(text, token: token, userID: userID, keyboard: keyboard)
    }
    // Only oversized cards require extra messages.
    var cardID = messageID
    for (index, piece) in pieces.enumerated() where index > 0 {
      try Task.checkCancellation()
      body = ["chat_id": userID, "text": TelegramMarkdown.html(piece), "parse_mode": "HTML"]
      if index == pieces.count - 1, let keyboard {
        body["reply_markup"] = ["inline_keyboard": keyboard]
      }
      let sent: SentMessage = try await call(token: token, method: "sendMessage", body: body)
      cardID = sent.messageID
    }
    return cardID
  }

  private struct SentMessage: Decodable {
    let messageID: Int64
    enum CodingKeys: String, CodingKey { case messageID = "message_id" }
  }
  private struct Envelope<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
  }
  private enum APIError: Error { case failed, notModified }
  private struct TelegramAPIError: Decodable { let description: String }

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
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      // Telegram returns 400 for an unchanged edit; do not create a duplicate card.
      if method == "editMessageText", (response as? HTTPURLResponse)?.statusCode == 400,
        let error = try? JSONDecoder().decode(TelegramAPIError.self, from: data),
        error.description.contains("message is not modified") {
        throw APIError.notModified
      }
      throw APIError.failed
    }
    let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
    guard envelope.ok, let result = envelope.result else { throw APIError.failed }
    return result
  }
}

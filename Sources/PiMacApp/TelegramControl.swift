import Combine
import CryptoKit
import Foundation

struct TelegramUpdate: Decodable {
  let updateID: Int64
  let message: Message?
  let editedMessage: Message?
  let callbackQuery: CallbackQuery?

  enum CodingKeys: String, CodingKey {
    case updateID = "update_id"
    case message
    case editedMessage = "edited_message"
    case callbackQuery = "callback_query"
  }

  struct Message: Decodable {
    let messageID: Int64?
    let replyToMessage: RepliedMessage?
    let quote: TextQuote?
    let date: TimeInterval
    let from: Sender?
    let chat: Chat
    let text: String?
    let caption: String?
    let photo: [Photo]?
    let document: Document?

    enum CodingKeys: String, CodingKey {
      case messageID = "message_id"
      case replyToMessage = "reply_to_message"
      case date, from, chat, text, caption, photo, document, quote
    }
  }
  struct TextQuote: Decodable {
    let text: String
  }

  nonisolated static func promptText(_ text: String, quote: String?) -> String {
    guard let quote, !quote.isEmpty else { return text }
    let quoted = quote.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
    return "用户引用的原消息片段（仅针对这段引用回复）：\n\(quoted)\n\n用户回复：\n\(text)"
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
    if [
      "/sessions", "/projects", "/status", "/usage", "/accounts", "/new", "/compact", "/stop",
      "/help", "/model", "/thinking", "/queue",
    ].contains(data) {
      return true
    }
    if TelegramPresentation.choiceKind(data) != nil { return true }
    if TelegramQueuePresentation.cancellation(data) != nil { return true }
    if data.hasPrefix("/queue "), let page = Int(data.dropFirst(7)) { return page > 0 }
    if data.hasPrefix("cancel:"), UUID(uuidString: String(data.dropFirst(7))) != nil { return true }
    if data.hasPrefix("session:") {
      let identifier = data.dropFirst(8)
      return identifier.count == 32 && identifier.allSatisfy { $0.isHexDigit && $0.isASCII }
    }
    if data.hasPrefix("/usage "), let page = Int(data.dropFirst(7)) { return page > 0 }
    if data.hasPrefix("/accounts "), let page = Int(data.dropFirst(10)) { return page > 0 }
    if data.hasPrefix("/status "), let page = Int(data.dropFirst(8)) { return page > 0 }
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

  func authorizedEdit(userID: Int64) -> Message? {
    guard let editedMessage, editedMessage.chat.type == "private",
      editedMessage.chat.id == userID, editedMessage.from?.id == userID,
      editedMessage.from?.isBot == false
    else { return nil }
    return editedMessage
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

  mutating func updateFirst(where predicate: (Element) -> Bool, transform: (inout Element) -> Void)
    -> Int?
  {
    guard let index = items.firstIndex(where: predicate) else { return nil }
    transform(&items[index])
    return index + 1
  }

  mutating func removeFirst(where predicate: (Element) -> Bool) -> Element? {
    guard let index = items.firstIndex(where: predicate) else { return nil }
    return items.remove(at: index)
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
      let saved = try? JSONDecoder().decode([Int64: Location].self, from: data)
    {
      entries = saved
    }
  }

  subscript(messageID: Int64) -> Location? { entries[messageID] }

  mutating func remember(
    _ messageID: Int64, location: Location,
    defaults: UserDefaults = .standard, maxCount: Int = limit
  ) {
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
  private var retryWorkerID = UUID()
  private var outboxPaused = false
  private var retryNotBefore = Date.distantPast
  private var inFlightReplyIDs: Set<UUID> = []

  /// Retry transport only; preserve running task subscriptions, queues and card revisions.
  func reconnect() {
    task?.cancel()
    task = nil
    retryTask?.cancel()
    retryTask = nil
    retryWorkerID = UUID()
    outboxPaused = false
    retryNotBefore = .distantPast
    connectTransport()
  }
  private var statusRefreshTasks: [Int64: Task<Void, Never>] = [:]
  private var remoteModels: [String: AppModel] = [:]
  private var warmProjectIDs: [String] = []
  private var desktopObservations: [ObjectIdentifier: AnyCancellable] = [:]
  private var replyModels: [String: AppModel] = [:]
  private var messageSessions = TelegramMessageSessionStore()
  private var acknowledgementIDs: [Int64: Int64] = [:]
  private var queueReceiptIDs: [Int64: Int64] = [:]
  private let cardUpdates = TelegramCardUpdates()
  private struct CompletedProgress {
    let text: String
    let keyboard: [[[String: String]]]?
    let location: TelegramMessageSessionStore.Location?
    let delivered: Bool?
  }
  private var completedProgress: [UUID: CompletedProgress] = [:]
  private var completionOrder: [UUID] = []
  private var sessionButtons: [[[String: String]]] = []
  private var displayedSessions: [String: SessionItem] = [:]
  // Only command cards sent during this run may be edited; old/unknown messages
  // (including agent replies with legacy keyboards) must remain untouched.
  private var editableCards: Set<Int64> = []
  // Mutation buttons are bound to the session displayed when their card was sent.
  private var cardLocations: [Int64: TelegramMessageSessionStore.Location] = [:]
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
  private var progressContexts: [UUID: (model: AppModel, startedAt: Date)] = [:]
  // Only cards currently showing status receive timer updates.
  private var progressViews: [Int64: UUID] = [:]
  private var pendingModels: Set<ObjectIdentifier> = []
  private struct RemotePrompt {
    let id = UUID()
    let receivedAt = Date()
    var preview: String
    var text: String
    let attachments: [PromptAttachment]
    let token: String
    let userID: Int64
    let generation: UUID
    let messageID: Int64?
    let mediaID: String?
  }
  private var promptQueues: [ObjectIdentifier: TelegramPromptQueue<RemotePrompt>] = [:]
  private var queueObservations: [ObjectIdentifier: AnyCancellable] = [:]
  private let queueScheduler = TelegramTaskScheduler()
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
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    messageSessions = TelegramMessageSessionStore(defaults: defaults)
    unsentReplies = TelegramUnsentReplyStore.load(defaults: defaults)
    pendingNotices = TelegramPendingNoticeStore.load(defaults: defaults)
    pendingFiles = TelegramPendingFileStore.load(defaults: defaults)
  }

  nonisolated static let allowedUpdates = ["message", "edited_message", "callback_query"]

  var enabled: Bool { defaults.bool(forKey: "telegram.enabled") }
  var userID: String { defaults.string(forKey: "telegram.userID") ?? "" }
  var botToken: String { TelegramTokenStore.load(defaults: defaults) }

  nonisolated static func validCredentials(token: String, userID: String) -> Bool {
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    let userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    return Int64(userID).map { $0 > 0 } == true
      && token.range(of: #"^[0-9]+:[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
  }

  /// Explain destructive preference changes before applying them. Initial setup is harmless.
  func configurationImpact(token: String, userID: String, enabled: Bool) -> String? {
    let credentialsChanged =
      token.trimmingCharacters(in: .whitespacesAndNewlines) != botToken
      || userID.trimmingCharacters(in: .whitespacesAndNewlines) != self.userID
    if credentialsChanged && (!botToken.isEmpty || !self.userID.isEmpty) {
      return "更换或删除凭据会清空等待任务、未送达消息和原消息的会话关联。正在 Mac 上执行的任务不会停止，但结果可能无法回传。"
    }
    if self.enabled && !enabled {
      return "停用会清空尚未执行的 Telegram 等待任务。正在 Mac 上执行的任务不会停止，但本次结果不再自动回传。未送达消息会保留，重新启用后重试。"
    }
    return nil
  }

  var canRestartSafely: Bool {
    pendingModels.isEmpty && replies.isEmpty && sendingReplies == 0
      && promptQueues.values.allSatisfy(\.isEmpty)
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
    if enabled, !Self.validCredentials(token: token, userID: userID) {
      throw ConfigurationError.invalid
    }
    // Saving unchanged preferences must not tear down subscriptions or queued prompts.
    if token == botToken, userID == self.userID, enabled == self.enabled,
      task != nil || !enabled
    {
      return
    }
    if token != botToken || userID != self.userID {
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
      queueReceiptIDs.removeAll()
    }
    TelegramTokenStore.save(token, defaults: defaults)
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
    for refresh in statusRefreshTasks.values { refresh.cancel() }
    statusRefreshTasks.removeAll()
    replies.removeAll()
    sessionPathObservations.removeAll()
    for progress in progressTasks.values { progress.cancel() }
    progressTasks.removeAll()
    progressCards.removeAll()
    progressContexts.removeAll()
    progressViews.removeAll()
    editableCards.removeAll()
    cardLocations.removeAll()
    acknowledgementIDs.removeAll()
    queueReceiptIDs.removeAll()
    cardUpdates.reset()
    completedProgress.removeAll()
    completionOrder.removeAll()
    pendingModels.removeAll()
    queueObservations.removeAll()
    queueScheduler.reset()
    lastQueueDiagnostic.removeAll()
    for retry in connectionRetries.values { retry.task.cancel() }
    connectionRetries.removeAll()
    for queue in promptQueues.values {
      for prompt in queue.items {
        for attachment in prompt.attachments {
          try? FileManager.default.removeItem(at: attachment.url)
        }
      }
    }
    promptQueues.removeAll()
    // Workspace owns the runtimes. Disabling the transport must not abort desktop work.
    for model in remoteModels.values { rememberSession(model) }
    for model in Array(remoteModels.values) + Array(replyModels.values) {
      model.onTelegramLifecycleEvent = nil
    }
    remoteModels.removeAll()
    warmProjectIDs.removeAll()
    desktopObservations.removeAll()
    replyModels.removeAll()
    status = "已停止"
    connectionState = .disconnected
  }

  private func restart() {
    stop()
    outboxPaused = false
    retryNotBefore = .distantPast
    connectTransport()
  }

  private func connectTransport() {
    guard enabled else {
      status = "未启用"
      return
    }
    let token = botToken
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
      var offset = TelegramUpdateCursorStore.load(defaults: self?.defaults ?? .standard) ?? 0
      var commandsRegistered = false
      var retryPolicy = TelegramRetryPolicy()
      while !Task.isCancelled {
        do {
          if !commandsRegistered {
            let registered: Bool = try await Self.call(
              token: token, method: "setMyCommands",
              body: ["commands": Self.botCommands, "scope": ["type": "chat", "chat_id": id]])
            guard registered else { throw APIError.failed }
            commandsRegistered = true
            guard self?.generation == generation, !Task.isCancelled else { break }
            self?.status = "已连接 · 仅允许用户 \(id)"
            self?.connectionState = .connected
          }
          let updates: [TelegramUpdate] = try await Self.call(
            token: token, method: "getUpdates",
            body: ["offset": offset, "timeout": 25, "allowed_updates": Self.allowedUpdates])
          guard !Task.isCancelled else { break }
          guard self?.generation == generation else { break }
          if self?.outboxPaused != true { self?.status = "已连接 · 仅允许用户 \(id)" }
          self?.connectionState = .connected
          retryPolicy.reset()
          // An empty first poll still establishes the initial cursor, so messages
          // arriving while the app is closed after this point are not age-filtered.
          if let self, TelegramUpdateCursorStore.load(defaults: self.defaults) == nil {
            TelegramUpdateCursorStore.save(offset, defaults: self.defaults)
          }
          for update in updates {
            guard !Task.isCancelled, self?.generation == generation else { break }
            guard update.updateID >= offset, update.updateID < Int64.max else { continue }
            // Checkpoint before dispatch: network errors or restarts must not run
            // an already accepted prompt a second time.
            offset = update.updateID + 1
            guard let self else { continue }
            TelegramUpdateCursorStore.save(offset, defaults: self.defaults)
            if let callback = update.authorizedCallback(userID: id) {
              if let messageID = callback.messageID { self.cardUpdates.advance(messageID) }
              // A failed callback acknowledgement must not replay its command.
              let acknowledgement = Task {
                let _: Bool? = try? await Self.call(
                  token: token, method: "answerCallbackQuery",
                  body: ["callback_query_id": callback.id])
              }
              // A slow acknowledgement must not delay rendering or the next update.
              defer { acknowledgement.cancel() }
              guard self.generation == generation, !Task.isCancelled else { break }
              if !TelegramPresentation.canPerform(
                callback.command,
                card: callback.messageID.flatMap { self.cardLocations[$0] },
                selected: Self.cardLocation(for: self.selectedTaskModel))
              {
                // Keep the original task card and its timer intact; never mutate a different session.
                await self.deliverNotice(
                  "按钮已过期或属于其他会话，未操作。\n请重新打开「状态」或对应列表。",
                  token: token, userID: id, generation: generation,
                  keyboard: [
                    [
                      TelegramPresentation.button("📊 当前状态", "/status"),
                      TelegramPresentation.button("📁 项目", "/projects"),
                      TelegramPresentation.button("🗂 会话", "/sessions"),
                    ]
                  ])
                continue
              }
              if let messageID = callback.messageID {
                self.queueReceiptIDs = self.queueReceiptIDs.filter { $0.value != messageID }
                self.statusRefreshTasks.removeValue(forKey: messageID)?.cancel()
                self.progressViews.removeValue(forKey: messageID)
              }
              var reply = await self.handle(
                callback.command, token: token, userID: id, generation: generation,
                fromCallback: true)
              guard self.generation == generation, !Task.isCancelled else { break }
              if let messageID = callback.messageID,
                self.editableCards.contains(messageID),
                let model = self.selectedTaskModel,
                reply == self.sessionStatus(for: model),
                let context = self.progressContexts.first(where: { $0.value.model === model })
              {
                self.progressViews[messageID] = context.key
                reply = self.progressStatus(for: model, startedAt: context.value.startedAt)
              }
              let keyboard = self.keyboard(for: callback.command)
              let statusModel = self.selectedTaskModel.flatMap { model in
                (callback.command.hasPrefix("project:") || callback.command == "/status"
                  || callback.command == "/new" || callback.command.hasPrefix("select:"))
                  && reply.hasSuffix(self.sessionStatus(for: model))
                  ? model : nil
              }
              if let messageID = callback.messageID,
                Self.shouldEditCallback(
                  messageID: messageID, knownCards: self.editableCards,
                  command: callback.command)
              {
                await self.deliverNotice(
                  reply, token: token, userID: id, generation: generation,
                  keyboard: keyboard, editMessageID: messageID, statusModel: statusModel)
              } else {
                await self.deliverNotice(
                  reply, token: token, userID: id, generation: generation,
                  keyboard: keyboard, statusModel: statusModel)
              }
            } else if let message = update.authorizedEdit(userID: id) {
              let reply = self.syncQueuedEdit(message)
              if !reply.isEmpty {
                await self.deliverNotice(
                  reply, token: token, userID: id, generation: generation,
                  keyboard: self.queuedKeyboard(messageID: message.messageID),
                  editMessageID: message.messageID.flatMap { self.queueReceiptIDs[$0] },
                  sourceMessageID: message.messageID)
              }
            } else if let message = update.authorizedMessage(userID: id, since: since) {
              if let photo = message.photo?.last {
                let reply = await self.handleAttachment(
                  size: photo.fileSize, kind: "图片", caption: message.caption ?? "",
                  mediaID: photo.fileID,
                  token: token, userID: id, generation: generation,
                  messageID: message.messageID, replyToID: message.replyToMessage?.messageID,
                  quote: message.quote?.text,
                  download: { try await Self.downloadPhoto(photo, token: token) })
                guard self.generation == generation, !Task.isCancelled else { break }
                await self.deliverNotice(
                  reply, token: token, userID: id, generation: generation,
                  keyboard: self.queuedKeyboard(messageID: message.messageID),
                  sourceMessageID: message.messageID)
              } else if let document = message.document {
                let reply = await self.handleAttachment(
                  size: document.fileSize, kind: "文件", caption: message.caption ?? "",
                  mediaID: document.fileID,
                  token: token, userID: id, generation: generation,
                  messageID: message.messageID, replyToID: message.replyToMessage?.messageID,
                  quote: message.quote?.text,
                  download: { try await Self.downloadDocument(document, token: token) })
                guard self.generation == generation, !Task.isCancelled else { break }
                await self.deliverNotice(
                  reply, token: token, userID: id, generation: generation,
                  keyboard: self.queuedKeyboard(messageID: message.messageID),
                  sourceMessageID: message.messageID)
              } else if let text = message.text {
                let reply = await self.handle(
                  text, token: token, userID: id, generation: generation,
                  messageID: message.messageID, replyToID: message.replyToMessage?.messageID,
                  quote: message.quote?.text)
                guard self.generation == generation, !Task.isCancelled else { break }
                let keyboard =
                  self.queuedKeyboard(messageID: message.messageID)
                  ?? self.keyboard(for: text)
                await self.deliverNotice(
                  reply, token: token, userID: id, generation: generation, keyboard: keyboard,
                  sourceMessageID: message.messageID,
                  statusModel: self.selectedTaskModel.flatMap { model in
                    let command = text.split(whereSeparator: \.isWhitespace).first?
                      .components(separatedBy: "@").first?.lowercased()
                    return (command == "/status" || command == "/new")
                      && reply == self.sessionStatus(for: model) ? model : nil
                  })
              }
            }
          }
        } catch {
          guard !Task.isCancelled else { break }
          // Never display URLSession errors: their URLs contain the bot secret.
          guard self?.generation == generation else { break }
          guard let delay = retryPolicy.delay(for: error) else {
            self?.status = TelegramRetryPolicy.pausedMessage
            self?.connectionState = .failed("连接已暂停，需修正配置后重连")
            self?.outboxPaused = true
            break
          }
          self?.status = "Telegram 连接失败，\(Int(delay)) 秒后重试。"
          self?.connectionState = .failed("连接暂时不可用")
          try? await Task.sleep(for: .seconds(delay))
        }
      }
    }
  }

  private func handleAttachment(
    size: Int?, kind: String, caption: String, mediaID: String, token: String, userID: Int64,
    generation: UUID, messageID: Int64?, replyToID: Int64?, quote: String?,
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
      return await handle(
        caption, attachments: [attachment], token: token,
        userID: userID, generation: generation, messageID: messageID, replyToID: replyToID,
        quote: quote, mediaID: mediaID)
    } catch {
      return "\(kind)下载失败或超过 20 MB，请稍后重试。"
    }
  }

  nonisolated static func shouldEditCallback(
    messageID: Int64, knownCards: Set<Int64>, command: String
  ) -> Bool {
    knownCards.contains(messageID)
  }

  private static func cardLocation(for model: AppModel?) -> TelegramMessageSessionStore.Location? {
    guard let model, let project = model.projectURL?.standardizedFileURL.path else { return nil }
    return .init(project: project, sessionPath: model.currentSessionPath)
  }

  private func rememberCard(_ messageID: Int64, location: TelegramMessageSessionStore.Location?) {
    if editableCards.count >= 500 {
      editableCards.removeAll()
      cardLocations.removeAll()
    }
    editableCards.insert(messageID)
    cardUpdates.retain(editableCards)
    cardLocations[messageID] = location
  }

  static let botCommands: [[String: String]] = [
    ["command": "projects", "description": "查看项目列表"],
    ["command": "sessions", "description": "切换会话"],
    ["command": "status", "description": "查看状态"],
    ["command": "queue", "description": "查看、取消等待任务"],
    ["command": "model", "description": "选择模型"],
    ["command": "thinking", "description": "选择推理强度"],
    ["command": "usage", "description": "额度与账户"],
    ["command": "new", "description": "新会话"],
    ["command": "compact", "description": "压缩上下文"],
    ["command": "stop", "description": "停止当前任务并清空排队"],
    ["command": "help", "description": "查看帮助"],
  ]

  static let help = """
    Pi Mac · 使用指南
    先选项目，再发送文本、照片或文件。
    文件 ≤20 MB；忙碌时自动排队。

    会话
    /projects  选择项目
    /sessions  切换会话
    /status  查看状态
    /new  新会话
    /compact  压缩上下文

    设置
    /model  模型
    /thinking  推理强度
    /usage  额度与账户

    任务
    /queue  查看、取消等待任务
    /stop  停止当前任务并清空排队
    /help  使用指南

    回复旧消息 → 原会话，不改默认选择。
    等待任务可编辑；替换附件须取消重发。
    删除消息不取消任务；回传失败自动重试。
    过期按钮请重新打开列表。
    Mac 须保持运行；扩展确认在 Mac 完成。
    """

  private func keyboard(
    for text: String, cardModel: AppModel? = nil, includePendingTask: Bool = true
  ) -> [[[String: String]]]? {
    if let cancellation = TelegramQueuePresentation.cancellation(text) {
      return keyboard(for: "/queue \(cancellation.page)")
    }
    let command =
      text.split(maxSplits: 1, whereSeparator: \.isWhitespace).first
      .map { String($0).components(separatedBy: "@")[0].lowercased() } ?? ""
    guard
      [
        "/sessions", "/start", "/help", "/projects", "/status", "/usage", "/accounts", "/new",
        "/compact", "/stop", "/model", "/thinking", "/queue",
      ]
      .contains(command) || command.hasPrefix("select:") || command.hasPrefix("model:")
        || command.hasPrefix("thinking:") || command.hasPrefix("account:")
        || command.hasPrefix("session:") || TelegramPresentation.choiceKind(command) != nil
    else { return nil }
    func button(_ title: String, _ action: String) -> [String: String] {
      ["text": title, "callback_data": action]
    }
    var rows: [[[String: String]]] = []
    if command == "/sessions" { rows += sessionButtons }
    if command == "/queue" {
      let parts = text.split(whereSeparator: \.isWhitespace)
      rows += TelegramQueuePresentation.keyboard(
        items: queueItems(for: selectedTaskModel),
        page: parts.count == 2 ? Int(parts[1]) ?? 1 : 1)
    }
    if command == "/status", let workspace {
      let parts = text.split(whereSeparator: \.isWhitespace)
      let requested = parts.count == 2 ? Int(parts[1]) ?? 1 : 1
      let count = otherProjectStatusSummaries(in: workspace, model: selectedTaskModel).count
      let page = ProjectStatusOverview.page(requested, count: count)
      var navigation: [[String: String]] = []
      if page > 1 { navigation.append(button("⬅️ 上一页", "/status \(page - 1)")) }
      if page * ProjectStatusOverview.pageSize < count {
        navigation.append(button("下一页 ➡️", "/status \(page + 1)"))
      }
      if !navigation.isEmpty { rows.append(navigation) }
    }
    if command == "/projects", let workspace {
      let parts = text.split(whereSeparator: \.isWhitespace)
      let page = TelegramPresentation.page(
        parts.count == 2 ? Int(parts[1]) ?? 1 : 1,
        count: workspace.projects.count, size: TelegramPresentation.projectPageSize)
      let start = page.start
      let buttons = workspace.projects.dropFirst(start).prefix(page.end - start).enumerated().map {
        index, project in
        button(
          "\(project.id == (activeReplyLocation?.project ?? defaults.string(forKey: projectKey)) ? "✓ " : "")\(start + index + 1). \(TelegramPresentation.compactLabel(project.name, limit: 40))",
          TelegramPresentation.choiceCommand(.project, value: project.id))
      }
      // Project names are often similar or long; a full-width target avoids mis-taps.
      rows += buttons.map { [$0] }
      let navigation = TelegramPresentation.navigation(page, command: "/projects")
      if !navigation.isEmpty { rows.append(navigation) }
    }
    if command == "/model", let workspace,
      let model = remoteModel(in: workspace)
    {
      model.refreshModelPreferences()
      let parts = text.split(whereSeparator: \.isWhitespace)
      let page = TelegramPresentation.page(
        parts.count == 2 ? Int(parts[1]) ?? 1 : 1,
        count: model.models.count, size: TelegramPresentation.modelPageSize)
      let start = page.start
      let choices = model.models.dropFirst(start).prefix(page.end - start).map { item in
        button(
          "\(item.id == model.selectedModelId ? "✓ " : "")\(TelegramPresentation.compactLabel(item.id, limit: 45, preserveSuffix: true))",
          TelegramPresentation.choiceCommand(.model, value: item.id))
      }
      // Model identifiers are long; full-width buttons remain readable on phones.
      rows += choices.map { [$0] }
      let navigation = TelegramPresentation.navigation(page, command: "/model")
      if !navigation.isEmpty { rows.append(navigation) }
    }
    if command == "/thinking" || command.hasPrefix("thinking:"), let workspace,
      let model = remoteModel(in: workspace)
    {
      let choices = model.thinkingLevels.map { level in
        button("\(level == model.selectedThinkingLevel ? "✓ " : "")\(level)", "thinking:\(level)")
      }
      for offset in stride(from: 0, to: choices.count, by: 3) {
        rows.append(Array(choices[offset..<min(offset + 3, choices.count)]))
      }
    }
    if command == "/usage" || command == "/accounts" {
      let model = workspace.flatMap { remoteModel(in: $0) }
      let accounts = workspace?.extensionUI.usage(for: model).accounts ?? []
      let parts = text.split(whereSeparator: \.isWhitespace)
      let page = TelegramPresentation.page(
        parts.count == 2 ? Int(parts[1]) ?? 1 : 1,
        count: accounts.count, size: TelegramPresentation.accountPageSize)
      let choices = accounts.dropFirst(page.start).prefix(page.end - page.start).enumerated().map {
        index, account in
        button(
          "\(account.isActive ? "✓ " : "")\(page.start + index + 1). \(TelegramPresentation.compactLabel(account.name, limit: 32))",
          TelegramPresentation.choiceCommand(.account, value: account.name))
      }
      rows += choices.map { [$0] }
      // Accept legacy /accounts cards, but emit only the canonical /usage route.
      let navigation = TelegramPresentation.navigation(page, command: "/usage")
      if !navigation.isEmpty { rows.append(navigation) }
      rows.append([button("↻ 最新缓存", "/usage \(page.number)")])
    }
    let model = cardModel ?? selectedTaskModel
    let running =
      model.map {
        $0.isBusy || (includePendingTask && pendingModels.contains(ObjectIdentifier($0)))
          || promptQueues[ObjectIdentifier($0)]?.isEmpty == false || !$0.queuedPrompts.isEmpty
          || workspace?.extensionUI.hasPendingRequests(from: $0) == true
      } ?? false
    // A task from another session still gets navigation, but not misleading mutation buttons.
    let hasSession = model != nil && (cardModel == nil || cardModel === selectedTaskModel)
    rows += TelegramPresentation.footer(command: command, running: running, hasSession: hasSession)
    return rows
  }

  static func projectList(_ projects: ArraySlice<WorkspaceProject>, start: Int) -> String {
    projects.enumerated().map { "\(start + $0.offset + 1). \($0.element.name)" }.joined(
      separator: "\n")
  }

  /// Routing references must remain stable when the desktop switches conversations.
  func retainsSession(_ model: AppModel) -> Bool {
    remoteModels.values.contains { $0 === model }
      || replyModels.values.contains { $0 === model }
  }

  /// Read routing state without starting a process or doing disk/network work.
  private var selectedTaskModel: AppModel? {
    if let location = activeReplyLocation {
      return replyModels[location.sessionPath]
        ?? remoteModels[location.project].flatMap {
          $0.currentSessionPath == location.sessionPath ? $0 : nil
        }
    }
    guard let project = defaults.string(forKey: projectKey) else { return nil }
    return remoteModels[project]
  }

  /// The active remote selection is equivalent to the selected desktop tab. Other
  /// idle remote tabs may still be suspended, keeping the process pool bounded.
  func keepsProcessWarm(_ model: AppModel) -> Bool {
    selectedTaskModel === model
      || warmProjectIDs.contains { remoteModels[$0] === model }
      || pendingModels.contains(ObjectIdentifier(model))
      || promptQueues[ObjectIdentifier(model)]?.isEmpty == false
  }

  /// Keep at most two recently selected projects warm for quick back-and-forth switches.
  /// The workspace still handles suspension and protects tasks/desktop selection.
  func selectProject(_ project: WorkspaceProject, in workspace: WorkspaceModel) -> AppModel? {
    let previousPath = defaults.string(forKey: projectKey)
    if let previousPath, let previous = remoteModels[previousPath] { rememberSession(previous) }
    warmProjectIDs.removeAll { $0 == project.id }
    if let previousPath, previousPath != project.id, !warmProjectIDs.contains(previousPath) {
      warmProjectIDs.insert(previousPath, at: 0)
    }
    warmProjectIDs.insert(project.id, at: 0)
    warmProjectIDs = Array(warmProjectIDs.prefix(2))
    defaults.set(project.id, forKey: projectKey)
    activeReplyLocation = nil
    let model = remoteModel(for: project, in: workspace)
    workspace.remoteSelectionChanged()
    return model
  }

  private func remoteModel(in workspace: WorkspaceModel) -> AppModel? {
    guard let path = defaults.string(forKey: projectKey),
      let project = workspace.projects.first(where: { $0.id == path }) ?? workspace.projects.first
    else { return nil }
    return remoteModel(for: project, in: workspace)
  }

  private func remoteModel(for project: WorkspaceProject, in workspace: WorkspaceModel) -> AppModel
  {
    if let model = remoteModels[project.id] {
      if !model.isProcessRunning, case .disconnected = model.connectionState {
        model.resumeProcess(
          sessionPath: model.currentSessionPath.isEmpty ? nil : model.currentSessionPath,
          continueLastSession: false)
      }
      return model
    }
    let savedPaths = defaults.dictionary(forKey: sessionsKey) as? [String: String] ?? [:]
    let sessionPath = savedPaths[project.id].flatMap { path in
      workspace.sessions(in: project.url).contains(where: { $0.path == path }) ? path : nil
    }
    if let sessionPath, let existing = replyModels.removeValue(forKey: sessionPath) {
      remoteModels[project.id] = existing
      return existing
    }
    let model = workspace.taskModel(in: project.url, sessionPath: sessionPath)
    remoteModels[project.id] = model
    observeDesktopUpdates(in: model)
    return model
  }

  static func routeLocation(
    replyToID: Int64?,
    sessions: TelegramMessageSessionStore, active: TelegramMessageSessionStore.Location?
  ) -> TelegramMessageSessionStore.Location? {
    if let replyToID { return sessions[replyToID] }
    return active
  }

  private func activeModel(in workspace: WorkspaceModel) async -> AppModel? {
    if let location = activeReplyLocation { return await replyModel(for: location, in: workspace) }
    return remoteModel(in: workspace)
  }

  private func replyModel(
    for location: TelegramMessageSessionStore.Location,
    in workspace: WorkspaceModel
  ) async -> AppModel? {
    guard let project = workspace.projects.first(where: { $0.id == location.project }),
      workspace.sessions(in: project.url).contains(where: { $0.path == location.sessionPath })
    else { return nil }
    // Persisted Telegram bindings resolve only against the authoritative T3 catalog.
    if let primary = remoteModels[project.id], primary.currentSessionPath == location.sessionPath {
      return primary
    }
    if let existing = replyModels[location.sessionPath] {
      if !existing.isProcessRunning, case .disconnected = existing.connectionState {
        existing.resumeProcess(sessionPath: location.sessionPath, continueLastSession: false)
      }
      return existing
    }
    let model = workspace.taskModel(in: project.url, sessionPath: location.sessionPath)
    replyModels[location.sessionPath] = model
    observeDesktopUpdates(in: model)
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

  private func rememberAcknowledgement(
    _ cardID: Int64?, for sourceMessageID: Int64?, wasQueued: Bool
  ) {
    guard let sourceMessageID, let cardID else { return }
    if queuedKeyboard(messageID: sourceMessageID) != nil || wasQueued {
      if queueReceiptIDs.count >= 500 { queueReceiptIDs.removeAll() }
      queueReceiptIDs[sourceMessageID] = cardID
      if wasQueued, queuedKeyboard(messageID: sourceMessageID) == nil {
        refreshQueueReceipt(
          sourceMessageID: sourceMessageID,
          text: "任务已不在队列，未重新提交。\n请查看状态或结果。")
      }
    }
    if let location = messageSessions[sourceMessageID] {
      messageSessions.remember(cardID, location: location, defaults: defaults)
    } else {
      if acknowledgementIDs.count >= 500 { acknowledgementIDs.removeAll() }
      acknowledgementIDs[sourceMessageID] = cardID
    }
  }

  private static let sessionPageSize = 5

  private func sessionsMessage(
    page: Int, project: WorkspaceProject, model: AppModel,
    sessions: [SessionItem]
  ) -> String {
    sessionButtons.removeAll()
    displayedSessions.removeAll()
    let entries = Self.sessionChoices(
      sessions, currentPath: model.currentSessionPath,
      currentTitle: Self.sessionListTitle(
        name: model.sessionName,
        firstPrompt: model.messages.first(where: { $0.kind == .user })?.text))
    guard !entries.isEmpty else { return "暂无历史会话 · 发消息或 /new 开始" }
    let pagination = TelegramPresentation.page(
      page, count: entries.count, size: Self.sessionPageSize)
    let start = pagination.start
    let currentTitle = Self.sessionListTitle(
      name: model.sessionName, firstPrompt: model.messages.first(where: { $0.kind == .user })?.text)
    var lines = [
      "会话 · \(entries.count) 个 · \(pagination.number)/\(pagination.count) 页",
      "项目  \(TelegramPresentation.compactLabel(project.name, limit: 32))",
      "当前  \(TelegramPresentation.compactLabel(currentTitle, limit: 32))", "",
    ]
    for (index, entry) in entries.dropFirst(start).prefix(Self.sessionPageSize).enumerated() {
      let current = entry.path == model.currentSessionPath
      let title = Self.sessionListTitle(name: entry.title, firstPrompt: nil)
      let token = Self.sessionIdentifier(project: project.id, path: entry.path)
      displayedSessions[token] = entry
      sessionButtons.append([
        [
          "text":
            "\(current ? "✓ " : "")\(start + index + 1). \(TelegramPresentation.compactLabel(title, limit: 36))",
          "callback_data": "session:\(token)",
        ]
      ])
    }
    let navigation = TelegramPresentation.navigation(pagination, command: "/sessions")
    if !navigation.isEmpty { sessionButtons.append(navigation) }
    lines.append("✓ 当前会话 · 空闲时可切换\n回复旧消息可单次继续原会话。")
    return lines.joined(separator: "\n")
  }

  nonisolated static func sessionIdentifier(project: String, path: String) -> String {
    let digest = SHA256.hash(data: Data("\(project)\u{0}\(path)".utf8))
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  nonisolated static func sessionForIdentifier(
    _ identifier: String, project: String,
    sessions: [SessionItem]
  ) -> SessionItem? {
    sessions.first { sessionIdentifier(project: project, path: $0.path) == identifier }
  }

  nonisolated static func sessionChoices(
    _ sessions: [SessionItem], currentPath: String,
    currentTitle: String
  ) -> [SessionItem] {
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
    sourceMessageID: Int64? = nil, statusModel: AppModel? = nil
  ) async {
    guard self.generation == generation, !Task.isCancelled else { return }
    sendingReplies += 1
    defer { sendingReplies -= 1 }
    var deliveredChunks = 0
    let cardRevision = editMessageID.map { cardUpdates.current($0) }
    let cardLocation = Self.cardLocation(for: statusModel ?? selectedTaskModel)
    // Startup may finish while Telegram is sending the initial card.
    let shouldRefresh =
      statusModel.map {
        Self.needsStatusRefresh($0) || !text.hasSuffix(sessionStatus(for: $0))
      } ?? false
    do {
      let cardID: Int64?
      if let editMessageID {
        let revision = cardRevision ?? cardUpdates.current(editMessageID)
        var result: Result<Int64?, Error>?
        let performed = await cardUpdates.enqueue(editMessageID, revision: revision) {
          guard self.generation == generation else { return }
          do {
            result = .success(
              try await Self.editOrSend(
                text, token: token, userID: userID, messageID: editMessageID, keyboard: keyboard))
          } catch { result = .failure(error) }
        }.value
        guard performed, let result else { return }
        cardID = try result.get()
      } else {
        cardID = try await Self.send(
          text, token: token, userID: userID, keyboard: keyboard,
          onSent: { _ in deliveredChunks += 1 })
      }
      guard self.generation == generation else { return }
      if keyboard != nil, let cardID { rememberCard(cardID, location: cardLocation) }
      rememberAcknowledgement(
        cardID, for: sourceMessageID,
        wasQueued: text.hasPrefix("📥 任务已排队") || text.hasPrefix("✏️ 排队任务已更新"))
      if let statusModel, let cardID,
        shouldRefresh || Self.needsStatusRefresh(statusModel)
      {
        refreshStatusWhenReady(
          for: statusModel, cardID: cardID, token: token, userID: userID,
          generation: generation, keyboard: keyboard)
      }
    } catch {
      guard self.generation == generation, !Task.isCancelled else { return }
      pendingNotices.append(
        TelegramPendingNotice(
          id: UUID(), text: text, keyboard: keyboard, sourceMessageID: sourceMessageID,
          editMessageID: editMessageID, deliveredChunks: deliveredChunks, cardRevision: cardRevision
        ))
      TelegramPendingNoticeStore.save(pendingNotices, defaults: defaults)
      status = "Telegram 消息发送失败，正在后台重试。"
      scheduleReplyRetry(token: token, userID: userID, generation: generation, after: error)
    }
  }

  private func scheduleReplyRetry(
    token: String, userID: Int64, generation: UUID, after error: Error? = nil
  ) {
    if let error {
      var policy = TelegramRetryPolicy()
      guard let delay = policy.delay(for: error) else {
        if !(error is CancellationError) {
          outboxPaused = true
          status = TelegramRetryPolicy.pausedMessage
        }
        return
      }
      retryNotBefore = max(retryNotBefore, Date().addingTimeInterval(delay))
    }
    guard retryTask == nil, !outboxPaused,
      !pendingNotices.isEmpty || !unsentReplies.isEmpty || !pendingFiles.isEmpty
    else { return }
    let workerID = UUID()
    retryWorkerID = workerID
    retryTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.generation == generation, self.retryWorkerID == workerID { self.retryTask = nil }
      }
      var retryPolicy = TelegramRetryPolicy()
      await TelegramOutboxRetry.run(
        allowed: { self.generation == generation && !self.outboxPaused },
        cooldown: { self.retryNotBefore.timeIntervalSinceNow }
      ) {
        var retryDelay: Double = 0
        let notices = self.pendingNotices
        let replies = self.unsentReplies.keys.sorted().flatMap { project in
          (self.unsentReplies[project] ?? []).filter { !self.inFlightReplyIDs.contains($0.id) }.map
          { (project, $0) }
        }
        let files = self.pendingFiles
        guard !notices.isEmpty || !replies.isEmpty || !files.isEmpty else { return nil }

        for notice in notices {
          guard self.generation == generation, !Task.isCancelled else { break }
          self.sendingReplies += 1
          let delivered: Bool
          do {
            let cardID: Int64?
            if let editID = notice.editMessageID {
              let currentRevision = self.cardUpdates.current(editID)
              guard let revision = notice.cardRevision, revision == currentRevision else {
                // Navigation or restart invalidated this old page. Never overwrite a newer card.
                self.pendingNotices.removeAll { $0.id == notice.id }
                TelegramPendingNoticeStore.save(self.pendingNotices, defaults: self.defaults)
                self.sendingReplies -= 1
                continue
              }
              var result: Result<Int64?, Error>?
              let performed = await self.cardUpdates.enqueue(editID, revision: revision) {
                guard self.generation == generation else { return }
                do {
                  result = .success(
                    try await Self.editOrSend(
                      notice.text, token: token,
                      userID: userID, messageID: editID, keyboard: notice.keyboard))
                } catch { result = .failure(error) }
              }.value
              if performed, let result { cardID = try result.get() } else { cardID = nil }
            } else {
              cardID = try await Self.send(
                notice.text, token: token, userID: userID, keyboard: notice.keyboard,
                startingAt: notice.deliveredChunks ?? 0,
                allowed: { [weak self] in self?.generation == generation },
                onSent: { _ in
                  guard self.generation == generation,
                    let index = self.pendingNotices.firstIndex(where: { $0.id == notice.id })
                  else { return }
                  self.pendingNotices[index].deliveredChunks =
                    (self.pendingNotices[index].deliveredChunks ?? 0) + 1
                  TelegramPendingNoticeStore.save(self.pendingNotices, defaults: self.defaults)
                })
            }
            if self.generation == generation, let cardID {
              // Retried notices may describe an old selection; require a fresh page for mutations.
              if notice.keyboard != nil { self.rememberCard(cardID, location: nil) }
              self.rememberAcknowledgement(
                cardID, for: notice.sourceMessageID,
                wasQueued: notice.text.hasPrefix("📥 任务已排队") || notice.text.hasPrefix("✏️ 排队任务已更新"))
            }
            delivered = true
          } catch {
            delivered = false
            guard let delay = retryPolicy.delay(for: error) else {
              self.sendingReplies -= 1
              if !Task.isCancelled, self.generation == generation {
                self.outboxPaused = true
                self.status = TelegramRetryPolicy.pausedMessage
              }
              return nil
            }
            retryDelay = max(retryDelay, delay)
          }
          self.sendingReplies -= 1
          guard self.generation == generation, !Task.isCancelled else { return nil }
          if delivered {
            self.pendingNotices.removeAll { $0.id == notice.id }
            TelegramPendingNoticeStore.save(self.pendingNotices, defaults: self.defaults)
          } else {
            return max(5, retryDelay)
          }
        }
        for (project, reply) in replies {
          guard self.generation == generation, !Task.isCancelled else { break }
          TelegramDeliveryLog.record(
            "retry_started", task: reply.id,
            sessionPath: reply.sessionPath)
          self.sendingReplies += 1
          let delivered: Bool
          do {
            try await Self.send(
              reply.text, token: token, userID: userID,
              startingAt: reply.deliveredChunks ?? 0,
              allowed: { [weak self] in self?.generation == generation },
              onSent: { [weak self] id in
                guard let self, self.generation == generation else { return }
                if let index = self.unsentReplies[project]?.firstIndex(where: { $0.id == reply.id })
                {
                  self.unsentReplies[project]![index].deliveredChunks =
                    (self.unsentReplies[project]![index].deliveredChunks ?? 0) + 1
                  TelegramUnsentReplyStore.save(self.unsentReplies, defaults: self.defaults)
                }
                guard !reply.sessionPath.isEmpty else { return }
                self.messageSessions.remember(
                  id,
                  location: .init(
                    project: project, sessionPath: reply.sessionPath), defaults: self.defaults)
              })
            delivered = true
            TelegramDeliveryLog.record(
              "retry_succeeded", task: reply.id,
              sessionPath: reply.sessionPath)
          } catch {
            delivered = false
            TelegramDeliveryLog.record(
              "retry_failed", task: reply.id,
              sessionPath: reply.sessionPath,
              details: "errorType=\(String(describing: type(of: error)))")
            guard let delay = retryPolicy.delay(for: error) else {
              self.sendingReplies -= 1
              if !Task.isCancelled, self.generation == generation {
                self.outboxPaused = true
                self.status = TelegramRetryPolicy.pausedMessage
              }
              return nil
            }
            retryDelay = max(retryDelay, delay)
          }
          self.sendingReplies -= 1
          guard self.generation == generation, !Task.isCancelled else { return nil }
          if delivered {
            self.unsentReplies[project]?.removeAll { $0.id == reply.id }
            if self.unsentReplies[project]?.isEmpty == true {
              self.unsentReplies.removeValue(forKey: project)
            }
            TelegramUnsentReplyStore.save(self.unsentReplies, defaults: self.defaults)
          } else {
            return max(5, retryDelay)
          }
        }
        // A first delivery may still be sending its checkpointed text.
        if !self.inFlightReplyIDs.isEmpty { return nil }
        for file in files {
          guard self.generation == generation, !Task.isCancelled else { break }
          self.sendingReplies += 1
          let delivered: Bool
          do {
            let url = try Self.validOutputFile(file.filePath, projectPath: file.projectPath)
            try await Self.sendDocument(
              url, token: token, userID: userID,
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
            guard let delay = retryPolicy.delay(for: error) else {
              self.sendingReplies -= 1
              if !Task.isCancelled, self.generation == generation {
                self.outboxPaused = true
                self.status = TelegramRetryPolicy.pausedMessage
              }
              return nil
            }
            retryDelay = max(retryDelay, delay)
          }
          self.sendingReplies -= 1
          guard self.generation == generation, !Task.isCancelled else { return nil }
          if delivered {
            self.pendingFiles.removeAll { $0.id == file.id }
            TelegramPendingFileStore.save(self.pendingFiles, defaults: self.defaults)
          } else {
            return max(5, retryDelay)
          }
        }
        retryPolicy.reset()
        return 0
      }
    }
  }

  // The remote AppModel starts its RPC process on the next main-actor turn. On the
  // first /status after launch, wait for that startup and configuration to finish
  // instead of immediately reporting the temporary "待连接" state.
  static func waitForSessionStatus(in model: AppModel, timeout: TimeInterval = 17) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !Task.isCancelled && Date() < deadline {
      switch model.connectionState {
      case .connected where !model.isLoadingConfiguration, .failed:
        return
      default:
        try? await Task.sleep(for: .seconds(min(0.1, max(0, deadline.timeIntervalSinceNow))))
      }
    }
  }

  static func needsStatusRefresh(_ model: AppModel) -> Bool {
    switch model.connectionState {
    case .connecting: return true
    case .connected: return model.isLoadingConfiguration
    default: return false
    }
  }

  private func refreshStatusWhenReady(
    for model: AppModel, cardID: Int64, token: String, userID: Int64,
    generation: UUID, keyboard: [[[String: String]]]?
  ) {
    statusRefreshTasks.removeValue(forKey: cardID)?.cancel()
    statusRefreshTasks[cardID] = Task { @MainActor [weak self, weak model] in
      guard let model else { return }
      await Self.waitForSessionStatus(in: model)
      guard let self, !Task.isCancelled, self.generation == generation else { return }
      defer { self.statusRefreshTasks.removeValue(forKey: cardID) }
      // Do not overwrite another selection or publish a timeout as completed startup.
      guard self.selectedTaskModel === model, !Self.needsStatusRefresh(model) else { return }
      self.rememberSession(model)
      await self.deliverNotice(
        self.sessionStatus(for: model), token: token, userID: userID,
        generation: generation, keyboard: keyboard, editMessageID: cardID)
    }
  }

  /// Inspect every known runtime, including desktop tasks and historical Telegram replies,
  /// without resolving an active model (which can resume a suspended Pi process).
  func projectStatusSummaries(in workspace: WorkspaceModel) -> [ProjectActivitySummary] {
    let models =
      workspace.tabs.map(\.model) + Array(remoteModels.values) + Array(replyModels.values)
    let confirmations = Set(
      models.filter {
        workspace.extensionUI.hasPendingRequests(from: $0)
      }.map(ObjectIdentifier.init))
    return ProjectStatusOverview.summaries(
      projects: workspace.projects, models: models,
      selectedProjectPath: activeReplyLocation?.project ?? defaults.string(forKey: projectKey),
      remoteQueueCounts: promptQueues.mapValues { $0.items.count },
      pendingReplyModels: pendingModels, confirmationModels: confirmations,
      undeliveredCounts: unsentReplies.mapValues { replies in
        replies.filter { !inFlightReplyIDs.contains($0.id) }.count
      }.merging(
        Dictionary(grouping: pendingFiles, by: \.projectPath).mapValues(\.count),
        uniquingKeysWith: +))
  }

  private func otherProjectStatusSummaries(
    in workspace: WorkspaceModel, model: AppModel?
  ) -> [ProjectActivitySummary] {
    ProjectStatusOverview.visibleSummaries(projectStatusSummaries(in: workspace))
      .filter { $0.project.id != model?.projectURL?.standardizedFileURL.path }
  }

  private func sessionStatus(
    for model: AppModel, page: Int = 1, elapsed: String? = nil
  ) -> String {
    let detail = Self.statusMessage(
      project: model.projectURL?.lastPathComponent ?? "未选择", session: model.sessionName,
      sessionPath: model.currentSessionPath,
      firstPrompt: model.messages.first(where: { $0.kind == .user })?.text,
      connection: model.connectionState, busy: model.isBusy,
      loading: model.isLoadingConfiguration, detail: model.statusText,
      model: model.selectedModelId, thinking: model.selectedThinkingLevel,
      contextPercent: model.stats?.contextPercent,
      account: workspace?.extensionUI.usage(for: model).accounts.first(where: \.isActive)?.name,
      queuedCount: (promptQueues[ObjectIdentifier(model)]?.items.count ?? 0)
        + model.queuedPrompts.count,
      elapsed: elapsed,
      waitingForConfirmation: workspace?.extensionUI.hasPendingRequests(from: model) == true)
    guard let workspace else { return detail }
    let others = otherProjectStatusSummaries(in: workspace, model: model)
    guard !others.isEmpty else { return detail }
    return detail + "\n\n──────────\n\n"
      + ProjectStatusOverview.message(others, page: page, otherProjectsOnly: true)
  }

  private func handle(
    _ text: String, attachments: [PromptAttachment] = [], token: String, userID: Int64,
    generation: UUID, fromCallback: Bool = false,
    messageID: Int64? = nil, replyToID: Int64? = nil, quote: String? = nil,
    mediaID: String? = nil
  ) async -> String {
    var submittedAttachments = false
    defer {
      if !submittedAttachments {
        for attachment in attachments { try? FileManager.default.removeItem(at: attachment.url) }
      }
    }
    if fromCallback, let cancellation = TelegramQueuePresentation.cancellation(text) {
      return cancelQueuedPrompt(id: cancellation.id) + "\n\n──────────\n\n"
        + queueMessage(page: cancellation.page)
    }
    if fromCallback, text.hasPrefix("cancel:"),
      let id = UUID(uuidString: String(text.dropFirst(7)))
    {
      return cancelQueuedPrompt(id: id)
    }
    guard let workspace else { return "工作区不可用" }
    let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    let command =
      attachments.isEmpty
      ? (parts.first.map { String($0).components(separatedBy: "@")[0].lowercased() } ?? "") : ""
    switch command {
    case "/start", "/help": return Self.help
    case "/queue":
      return queueMessage(page: parts.count == 2 ? Int(parts[1]) ?? 1 : 1)
    case "/status":
      let page = parts.count == 2 ? Int(parts[1]) ?? 1 : 1
      if let model = await activeModel(in: workspace) {
        await Self.waitForSessionStatus(in: model, timeout: 0.35)
        guard generation == self.generation, !Task.isCancelled else {
          return "连接已重置，请重新发送命令。"
        }
        return sessionStatus(for: model, page: page)
      }
      let summaries = otherProjectStatusSummaries(in: workspace, model: nil)
      if summaries.isEmpty {
        return workspace.projects.isEmpty
          ? "尚无项目，请先在 Mac 上添加项目。"
          : "当前没有项目执行任务。请用 /projects 选择项目查看会话状态。"
      }
      return ProjectStatusOverview.message(summaries, page: page)
    case "/sessions":
      let currentModel = selectedTaskModel
      let resolvedModel = currentModel == nil ? await activeModel(in: workspace) : currentModel
      guard let model = resolvedModel, let projectURL = model.projectURL,
        let project = workspace.projects.first(where: {
          $0.id == projectURL.standardizedFileURL.path
        })
      else { return "请先用 /projects 选择项目。" }
      let sessions = workspace.sessions(in: project.url)
      guard generation == self.generation, !Task.isCancelled else { return "连接已重置，请重新发送命令。" }
      return sessionsMessage(
        page: parts.count == 2 ? Int(parts[1]) ?? 1 : 1,
        project: project, model: model, sessions: sessions)
    case let action where action.hasPrefix("session:") && fromCallback:
      let currentModel = selectedTaskModel
      let resolvedModel = currentModel == nil ? await activeModel(in: workspace) : currentModel
      guard let model = resolvedModel,
        let project = model.projectURL?.standardizedFileURL.path,
        workspace.projects.contains(where: { $0.id == project })
      else { return "请先用 /projects 选择项目。" }
      let identifier = String(action.dropFirst(8))
      if !model.currentSessionPath.isEmpty,
        Self.sessionIdentifier(project: project, path: model.currentSessionPath) == identifier
      {
        return "当前已在此会话。"
      }
      // Resolve visible buttons without rescanning all history. Old cards still
      // fall back to disk discovery, and replyModel validates the target file.
      var target = displayedSessions[identifier].flatMap {
        Self.sessionIdentifier(project: project, path: $0.path) == identifier ? $0 : nil
      }
      if target == nil {
        let sessions = workspace.sessions(in: URL(fileURLWithPath: project))
        target = Self.sessionForIdentifier(identifier, project: project, sessions: sessions)
      }
      guard generation == self.generation, !Task.isCancelled else { return "连接已重置，请重新发送命令。" }
      guard let target else { return "会话已不存在或不在当前项目，请用 /sessions 刷新。" }
      let location = TelegramMessageSessionStore.Location(
        project: project, sessionPath: target.path)
      guard let selected = await replyModel(for: location, in: workspace),
        generation == self.generation, !Task.isCancelled
      else { return "会话已不可用，请用 /sessions 刷新。" }
      activeReplyLocation = location
      defaults.set(project, forKey: projectKey)
      rememberSession(selected)
      workspace.remoteSelectionChanged()
      // Routing is ready now; Pi startup/configuration continues in the background.
      return
        "已切换会话\n\(TelegramPresentation.compactLabel(Self.sessionListTitle(name: target.title, firstPrompt: nil), limit: 32))"
    case "/projects":
      let page = TelegramPresentation.page(
        parts.count == 2 ? Int(parts[1]) ?? 1 : 1,
        count: workspace.projects.count, size: TelegramPresentation.projectPageSize)
      let selected = activeReplyLocation?.project ?? defaults.string(forKey: projectKey)
      let current = workspace.projects.first(where: { $0.id == selected })?.name ?? "未选择"
      return workspace.projects.isEmpty
        ? "暂无项目 · 请在 Mac 添加"
        : "项目 · \(workspace.projects.count) 个 · \(page.number)/\(page.count) 页\n当前  \(TelegramPresentation.compactLabel(current, limit: 32))\n\n✓ 当前项目 · 不改桌面选择"
    case let action
    where (action.hasPrefix("project:") || action.hasPrefix("select:")) && fromCallback:
      guard
        let index = TelegramPresentation.choiceIndex(
          action, kind: .project, values: workspace.projects.map(\.id))
      else { return "项目已失效，未切换。\n请重新打开「项目」。" }
      let project = workspace.projects[index]
      guard let model = selectProject(project, in: workspace) else { return "请先在 Mac 上添加项目。" }
      // Switching routes must not block the update loop on a cold Pi startup.
      // The card will be refreshed asynchronously when configuration finishes.
      await Self.waitForSessionStatus(in: model, timeout: 0.35)
      guard generation == self.generation, !Task.isCancelled else {
        return "连接已重置，请重新发送命令。"
      }
      return sessionStatus(for: model)
    default: break
    }
    if command == "/usage" || command == "/accounts" {
      let model = remoteModel(in: workspace)
      let usage = workspace.extensionUI.usage(for: model)
      return Self.usageMessage(
        accounts: usage.accounts, gemini: usage.gemini, updatedAt: usage.updatedAt,
        page: parts.count == 2 ? Int(parts[1]) ?? 1 : 1)
    }
    guard
      let model = await
        (replyToID == nil
        ? activeModel(in: workspace)
        : remoteModel(in: workspace))
    else {
      return activeReplyLocation == nil
        ? "请先在 Mac 上添加项目。"
        : "上次引用的会话已不可用，请用 /projects 重新选择项目。"
    }
    switch command {
    case let action
    where (action.hasPrefix("accountid:") || action.hasPrefix("account:")) && fromCallback:
      guard model.supportsAccountSwitch else {
        return "当前账户扩展未报告此提供商的切换能力，请升级 account-usage。"
      }
      let accounts = workspace.extensionUI.usage(for: model).accounts
      guard
        let index = TelegramPresentation.choiceIndex(
          action, kind: .account, values: accounts.map(\.name))
      else { return "账户已失效，未切换。\n请重新打开「额度」。" }
      guard canChangeConfiguration(in: model)
      else { return "暂不能切换账户 · 请等待任务及排队完成\n如有扩展确认，请在 Mac 处理。" }
      let account = accounts[index]
      if account.isActive {
        return "当前账户  \(TelegramPresentation.compactLabel(account.name, limit: 32))"
      }
      model.switchCodexAccount(to: account.name)
      return "账户切换待确认\n\(TelegramPresentation.compactLabel(account.name, limit: 32))\n点「状态」核实。"
    case "/model":
      model.refreshModelPreferences()
      let page = TelegramPresentation.page(
        parts.count == 2 ? Int(parts[1]) ?? 1 : 1,
        count: model.models.count, size: TelegramPresentation.modelPageSize)
      return model.models.isEmpty
        ? "模型列表加载中 · 请稍后重试"
        : "模型 · \(page.number)/\(page.count) 页\n当前  \(TelegramPresentation.compactLabel(model.selectedModelId, limit: 44, preserveSuffix: true))\n\n✓ 当前模型 · 空闲时可切换\n与桌面共用偏好。"
    case "/thinking":
      return
        "推理强度\n当前  \(model.selectedThinkingLevel)\n\n✓ 当前强度 · 空闲时可切换"
    case let action
    where (action.hasPrefix("modelid:") || action.hasPrefix("model:")) && fromCallback:
      model.refreshModelPreferences()
      guard
        let index = TelegramPresentation.choiceIndex(
          action, kind: .model, values: model.models.map(\.id))
      else { return "模型已失效，未切换。\n请重新打开「模型」。" }
      guard canChangeConfiguration(in: model)
      else { return "暂不能切换模型 · 请等待任务及排队完成\n如有扩展确认，请在 Mac 处理。" }
      let choice = model.models[index]
      if model.selectedModelId == choice.id {
        model.changeModel(to: choice.id)  // Explicit selection still pins the shared preference.
        return sessionStatus(for: model)
      }
      model.changeModel(to: choice.id)
      let deadline = Date().addingTimeInterval(2)
      while generation == self.generation && !Task.isCancelled && Date() < deadline {
        if model.selectedModelId == choice.id { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard generation == self.generation, !Task.isCancelled else {
        return "连接已重置，请重新发送命令。"
      }
      return TelegramPresentation.selectionFeedback(
        label: "模型", value: choice.id, confirmed: model.selectedModelId == choice.id)
        + "\n\n" + sessionStatus(for: model)
    case let action where action.hasPrefix("thinking:") && fromCallback:
      let level = String(action.dropFirst(9))
      guard model.thinkingLevels.contains(level) else { return "当前模型不支持此强度，请重新使用 /thinking。" }
      guard canChangeConfiguration(in: model)
      else { return "暂不能切换推理 · 请等待任务及排队完成\n如有扩展确认，请在 Mac 处理。" }
      if model.selectedThinkingLevel == level {
        model.changeThinkingLevel(to: level)
        return sessionStatus(for: model)
      }
      model.changeThinkingLevel(to: level)
      let deadline = Date().addingTimeInterval(2)
      while generation == self.generation && !Task.isCancelled && Date() < deadline {
        if model.selectedThinkingLevel == level { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard generation == self.generation, !Task.isCancelled else {
        return "连接已重置，请重新发送命令。"
      }
      return TelegramPresentation.selectionFeedback(
        label: "推理强度", value: level, confirmed: model.selectedThinkingLevel == level)
        + "\n\n" + sessionStatus(for: model)
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
      return "上下文压缩中 · 点「状态」查看进度"
    case "/stop":
      let modelID = ObjectIdentifier(model)
      let cancelled = promptQueues.removeValue(forKey: modelID)?.items ?? []
      queueObservations.removeValue(forKey: modelID)
      connectionRetries.removeValue(forKey: modelID)?.task.cancel()
      for prompt in cancelled {
        refreshQueueReceipt(
          sourceMessageID: prompt.messageID,
          text: "已取消此条 · 当前会话已请求停止")
        for attachment in prompt.attachments {
          try? FileManager.default.removeItem(at: attachment.url)
        }
      }
      model.abort()
      return "⏹ 已请求停止当前任务\n"
        + (cancelled.isEmpty ? "无 TG 等待任务" : "已取消 \(cancelled.count) 条 TG 等待任务")
        + "\n其他会话不变 · 状态卡将更新"
    case "/new":
      guard let projectURL = model.projectURL else { return "请先选择项目。" }
      let project = projectURL.standardizedFileURL.path
      // Keep the old runtime and its queues/subscriptions untouched. A new tab has
      // its own process, so tasks in the same project can genuinely run concurrently.
      if let previous = remoteModels[project], !previous.currentSessionPath.isEmpty {
        replyModels[previous.currentSessionPath] = previous
      }
      let fresh = workspace.taskModel(in: projectURL, sessionPath: nil)
      remoteModels[project] = fresh
      defaults.set(project, forKey: projectKey)
      activeReplyLocation = nil
      observeDesktopUpdates(in: fresh)
      rememberSession(fresh)
      workspace.remoteSelectionChanged()
      await Self.waitForSessionStatus(in: fresh, timeout: 0.35)
      guard generation == self.generation, !Task.isCancelled else {
        return "连接已重置，请重新发送命令。"
      }
      return sessionStatus(for: fresh)
    default:
      if command.hasPrefix("/") { return "未知命令。\n" + Self.help }
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
      else { return Self.help }
      let targetModel: AppModel
      if let replyToID {
        guard
          let location = Self.routeLocation(
            replyToID: replyToID,
            sessions: messageSessions, active: activeReplyLocation)
        else {
          return "找不到所回复消息关联的会话，请用 /sessions 选择会话。"
        }
        guard let resolved = await replyModel(for: location, in: workspace),
          generation == self.generation, !Task.isCancelled
        else {
          return "原会话已不可用，请用 /sessions 重新选择。"
        }
        // A reply is a one-message route, not a change to the user's selection.
        // Only explicit project/session selection changes subsequent plain messages.
        targetModel = resolved
      } else {
        targetModel = model
      }
      // Accept requests during startup and reconnect in the background. Never
      // force the user to resend a prompt solely because Pi is not yet ready.
      let prompt = RemotePrompt(
        preview: text, text: TelegramUpdate.promptText(text, quote: quote),
        attachments: attachments, token: token, userID: userID, generation: generation,
        messageID: messageID, mediaID: mediaID)
      let modelID = ObjectIdentifier(targetModel)
      if !canSubmitRemotePrompt(in: targetModel) || promptQueues[modelID]?.isEmpty == false {
        guard let position = promptQueues[modelID, default: .init()].append(prompt)
        else { return "等待队列已满，请稍后再试。" }
        associate(messageID, with: targetModel)
        TelegramDeliveryLog.record(
          "prompt_queued", task: prompt.id,
          sessionPath: targetModel.currentSessionPath,
          details: "position=\(position) blockers=\(queueBlockers(for: targetModel))")
        observeQueue(in: targetModel)
        submittedAttachments = true
        startConnectionRetry(for: targetModel)
        // If the previous turn settled while this update was being handled, drain now.
        scheduleQueueDrain(for: targetModel)
        return Self.queueNotice(
          project: targetModel.projectURL?.lastPathComponent ?? "当前项目",
          position: position, originalSession: replyToID != nil,
          waitingForConnection: !targetModel.clientConnectedForCommands
            || targetModel.isLoadingConfiguration,
          preview: text, attachmentCount: attachments.count,
          waitingForConfirmation: workspace.extensionUI.hasPendingRequests(from: targetModel))
      }
      submitRemotePrompt(prompt, in: targetModel)
      submittedAttachments = true
      let label = targetModel.projectURL?.lastPathComponent ?? "当前项目"
      return TelegramPresentation.taskNotice(
        project: label, originalSession: replyToID != nil,
        preview: text, attachmentCount: attachments.count)
    }
  }

  private func queueItems(for model: AppModel?) -> [TelegramQueuePresentation.Item] {
    guard let model else { return [] }
    return (promptQueues[ObjectIdentifier(model)]?.items ?? []).map {
      .init(
        id: $0.id, preview: $0.preview, attachmentCount: $0.attachments.count,
        receivedAt: $0.receivedAt)
    }
  }

  private func queueMessage(page: Int) -> String {
    guard let model = selectedTaskModel else {
      return "等待队列\n请先选择项目或会话。"
    }
    let blocker: String
    if workspace?.extensionUI.hasPendingRequests(from: model) == true {
      blocker = "待 Mac 确认，随后自动执行。"
    } else if !model.clientConnectedForCommands || model.isLoadingConfiguration {
      blocker = "连接重试中，无需重发。"
    } else {
      blocker = "就绪后自动执行。"
    }
    return TelegramQueuePresentation.card(
      project: model.projectURL?.lastPathComponent ?? "未选择",
      session: Self.sessionListTitle(
        name: model.sessionName,
        firstPrompt: model.messages.first(where: { $0.kind == .user })?.text),
      items: queueItems(for: model), localQueueCount: model.queuedPrompts.count,
      blocker: blocker, page: page)
  }

  private func refreshQueueReceipt(sourceMessageID: Int64?, text: String) {
    guard let sourceMessageID, let cardID = queueReceiptIDs.removeValue(forKey: sourceMessageID),
      editableCards.contains(cardID), let user = Int64(userID), user > 0
    else { return }
    let revision = cardUpdates.advance(cardID)
    let generation = generation
    let token = botToken
    _ = cardUpdates.enqueue(cardID, revision: revision) { [weak self] in
      guard let self, self.generation == generation else { return }
      try? await Self.editProgress(
        text, token: token, userID: user, messageID: cardID,
        keyboard: [
          [
            TelegramPresentation.button("📊 当前状态", "/status"),
            TelegramPresentation.button("📥 当前队列", "/queue"),
          ]
        ])
    }
  }

  private func queuedKeyboard(messageID: Int64?) -> [[[String: String]]]? {
    guard let messageID,
      let prompt = promptQueues.values.lazy.flatMap({ $0.items }).first(where: {
        $0.messageID == messageID && $0.generation == generation
      })
    else { return nil }
    return [[TelegramPresentation.button("✕ 取消此排队任务", "cancel:\(prompt.id.uuidString)")]]
  }

  private func syncQueuedEdit(_ message: TelegramUpdate.Message) -> String {
    guard let messageID = message.messageID else { return "" }
    for modelID in Array(promptQueues.keys) {
      guard
        let prompt = promptQueues[modelID]?.items.first(where: {
          $0.messageID == messageID && $0.generation == generation
        })
      else { continue }
      let editedMediaID = message.photo?.last?.fileID ?? message.document?.fileID
      guard editedMediaID == prompt.mediaID else {
        return "附件未替换 · 请取消此条后重发"
      }
      let text = message.text ?? message.caption ?? ""
      guard
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || !prompt.attachments.isEmpty
      else {
        return "编辑未同步 · 内容不能为空\n取消请用下方按钮。"
      }
      let position =
        promptQueues[modelID]?.updateFirst(
          where: { $0.id == prompt.id },
          transform: {
            $0.text = TelegramUpdate.promptText(text, quote: message.quote?.text)
            $0.preview = text
          }) ?? 1
      let project =
        messageSessions[messageID].map {
          URL(fileURLWithPath: $0.project).lastPathComponent
        } ?? "原项目"
      TelegramDeliveryLog.record(
        "prompt_edited", task: prompt.id,
        sessionPath: messageSessions[messageID]?.sessionPath ?? "",
        details: "position=\(position)")
      return
        "✏️ 排队任务已更新\n项目  \(TelegramPresentation.compactLabel(project, limit: 32))\n排队  第 \(position) 位 · 目标不变\n摘要  \(TelegramPresentation.compactLabel(text, limit: 48))"
    }
    // Never resubmit edits to commands, historical messages or already-running tasks.
    return messageSessions[messageID] == nil
      ? ""
      : "编辑未同步：此消息已不在等待队列（可能已开始执行或已取消），不会重新提交任务。"
  }

  private func cancelQueuedPrompt(id: UUID) -> String {
    for modelID in Array(promptQueues.keys) {
      guard
        let prompt = promptQueues[modelID]?.removeFirst(where: {
          $0.id == id && $0.generation == generation
        })
      else { continue }
      for attachment in prompt.attachments {
        try? FileManager.default.removeItem(at: attachment.url)
      }
      if promptQueues[modelID]?.isEmpty == true {
        promptQueues.removeValue(forKey: modelID)
        queueObservations.removeValue(forKey: modelID)
        connectionRetries.removeValue(forKey: modelID)?.task.cancel()
        lastQueueDiagnostic.removeValue(forKey: modelID)
      }
      refreshQueueReceipt(
        sourceMessageID: prompt.messageID,
        text: "已取消此条 · 其他任务不变")
      TelegramDeliveryLog.record(
        "prompt_cancelled", task: prompt.id,
        sessionPath: prompt.messageID.flatMap { messageSessions[$0]?.sessionPath } ?? "")
      return "已取消此条 · 其他任务不变"
    }
    return "此条已不在队列 · 未停止执行中的任务"
  }

  static func queueNotice(
    project: String, position: Int, originalSession: Bool, waitingForConnection: Bool,
    preview: String = "", attachmentCount: Int = 0, waitingForConfirmation: Bool = false
  ) -> String {
    TelegramPresentation.taskNotice(
      project: project, originalSession: originalSession, position: position,
      preview: preview, attachmentCount: attachmentCount,
      waitingForConnection: waitingForConnection, waitingForConfirmation: waitingForConfirmation)
  }

  private func canChangeConfiguration(in model: AppModel) -> Bool {
    model.clientConnectedForCommands && model.canRestartSafely
      && model.queuedPrompts.isEmpty
      && promptQueues[ObjectIdentifier(model)]?.isEmpty != false
      && !pendingModels.contains(ObjectIdentifier(model))
      && workspace?.extensionUI.hasPendingRequests(from: model) == false
  }

  private func canSubmitRemotePrompt(in model: AppModel) -> Bool {
    model.canSubmitPrompt && model.canRestartSafely
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
      now.timeIntervalSince(previous.date) < 30
    {
      return
    }
    lastQueueDiagnostic[id] = (reason, now)
    TelegramDeliveryLog.record(
      "queue_waiting", task: first.id,
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
      Self.shouldRetryConnection(
        model.connectionState,
        isLoading: model.isLoadingConfiguration, canRestart: model.canRestartSafely)
    else { return }
    if let first = promptQueues[id]?.first {
      TelegramDeliveryLog.record(
        "connection_retry", task: first.id,
        sessionPath: model.currentSessionPath)
    }
    if model.isProcessRunning { model.suspendProcess() }
    guard !model.isProcessRunning else { return }
    model.resumeProcess(
      sessionPath: model.currentSessionPath.isEmpty ? nil : model.currentSessionPath,
      continueLastSession: false)
  }

  /// Observe for the model's lifetime, including stats responses that arrive after settlement.
  private func observeDesktopUpdates(in model: AppModel) {
    let updates = Publishers.MergeMany([
      model.$messages.map { _ in () }.eraseToAnyPublisher(),
      model.$stats.map { _ in () }.eraseToAnyPublisher(),
      model.$currentSessionPath.map { _ in () }.eraseToAnyPublisher(),
      model.$sessionName.map { _ in () }.eraseToAnyPublisher(),
    ])
    desktopObservations[ObjectIdentifier(model)] =
      updates
      .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak model] _ in
        guard let self, let model else { return }
        self.workspace?.remoteSessionUpdated(from: model)
      }
  }

  func refreshDesktopSnapshots() {
    for model in Array(remoteModels.values) + Array(replyModels.values) {
      workspace?.remoteSessionUpdated(from: model)
    }
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
    queueScheduler.schedule(for: ObjectIdentifier(model)) { [weak self, weak model] in
      guard let self, let model else { return }
      let id = ObjectIdentifier(model)
      guard self.canSubmitRemotePrompt(in: model),
        let first = self.promptQueues[id]?.first, first.generation == self.generation
      else { return }
      TelegramDeliveryLog.record(
        "queue_drained", task: first.id,
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
    _ text: String, token: String, userID: Int64, messageID: Int64,
    keyboard: [[[String: String]]]? = nil
  ) async throws {
    var body: [String: Any] = [
      "chat_id": userID, "message_id": messageID,
      "text": TelegramMarkdown.html(text), "parse_mode": "HTML",
    ]
    body["reply_markup"] = ["inline_keyboard": keyboard ?? []]
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
    sessionStatus(for: model, elapsed: Self.progressElapsed(startedAt: startedAt))
  }

  private func recordCompletion(
    key: UUID, model: AppModel, outcome: TelegramPresentation.TaskOutcome,
    elapsed: String, delivered: Bool?
  ) {
    if completedProgress[key] == nil {
      completionOrder.append(key)
      if completionOrder.count > 100 {
        completedProgress.removeValue(forKey: completionOrder.removeFirst())
      }
    }
    let summary = TelegramPresentation.completionSummary(
      outcome: outcome, delivered: delivered, elapsed: elapsed,
      queuedCount: (promptQueues[ObjectIdentifier(model)]?.items.count ?? 0)
        + model.queuedPrompts.count)
    completedProgress[key] = CompletedProgress(
      text: summary + "\n\n──────────\n\n" + sessionStatus(for: model),
      keyboard: keyboard(for: "/status", cardModel: model, includePendingTask: false),
      location: Self.cardLocation(for: model), delivered: delivered)
  }

  private func updateCompletedCard(
    key: UUID, cardID: Int64, token: String, userID: Int64, generation: UUID
  ) async {
    let revision = cardUpdates.current(cardID)
    _ = await cardUpdates.enqueue(cardID, revision: revision) { [weak self] in
      guard let self, self.generation == generation, self.progressViews[cardID] == key else {
        return
      }
      // Read the latest delivery state only when this serialized edit is ready to send.
      let completion = self.completedProgress[key]
      do {
        try await Self.editProgress(
          completion?.text ?? "ℹ️ 任务已结束，请查看单独发送的结果。",
          token: token, userID: userID, messageID: cardID, keyboard: completion?.keyboard)
        guard self.generation == generation, self.progressViews[cardID] == key else { return }
        self.cardLocations[cardID] = completion?.location
        if completion == nil || completion?.delivered != nil {
          self.progressViews.removeValue(forKey: cardID)
        }
      } catch {
        // Result delivery is independent; transient cards are not persisted.
      }
    }.value
  }

  private func startProgress(
    key: UUID, model: AppModel, token: String, userID: Int64, generation: UUID,
    startedAt: Date
  ) {
    guard progressTasks[key] == nil, replies[key] != nil else { return }
    progressContexts[key] = (model, startedAt)
    progressTasks[key] = Task { @MainActor [weak self, weak model] in
      guard let self, let model, self.generation == generation, self.replies[key] != nil,
        !Task.isCancelled
      else { return }
      defer { self.progressTasks.removeValue(forKey: key) }
      let messageID: Int64?
      do {
        messageID = try await Self.send(
          self.progressStatus(for: model, startedAt: startedAt),
          token: token, userID: userID, keyboard: self.keyboard(for: "/status", cardModel: model),
          allowed: { [weak self] in self?.generation == generation && self?.replies[key] != nil })
      } catch { return }  // Progress is transient; do not persist or retry it.
      guard let messageID, self.generation == generation else { return }
      self.associate(messageID, with: model)
      self.rememberCard(messageID, location: Self.cardLocation(for: model))
      if self.replies[key] == nil {
        self.progressViews[messageID] = key
        await self.updateCompletedCard(
          key: key, cardID: messageID,
          token: token, userID: userID, generation: generation)
        return
      }
      self.progressCards[key] = messageID
      self.progressViews[messageID] = key
      while self.generation == generation && self.replies[key] != nil && !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(30)) } catch { break }
        guard self.generation == generation, self.replies[key] != nil, !Task.isCancelled else {
          break
        }
        for cardID in self.progressViews.filter({ $0.value == key }).map(\.key) {
          guard self.progressViews[cardID] == key, self.replies[key] != nil else { continue }
          let revision = self.cardUpdates.current(cardID)
          _ = await self.cardUpdates.enqueue(cardID, revision: revision) {
            guard self.generation == generation, self.progressViews[cardID] == key,
              self.replies[key] != nil
            else { return }
            let location = Self.cardLocation(for: model)
            do {
              try await Self.editProgress(
                self.progressStatus(for: model, startedAt: startedAt),
                token: token, userID: userID, messageID: cardID,
                keyboard: self.keyboard(for: "/status", cardModel: model))
              if self.generation == generation, self.progressViews[cardID] == key {
                self.cardLocations[cardID] = location
              }
            } catch {
              // Keep the previous card context if the edit was not delivered.
            }
          }.value
        }
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
      TelegramDeliveryLog.record(
        event, task: key, sessionPath: model.currentSessionPath,
        details: details)
    }
    log("submitted", "model=\(model.selectedModelId)")
    var lastStopReason: String?
    model.onTelegramLifecycleEvent = { [weak model] event in
      guard let model else { return }
      if event.hasPrefix("message_end "), let range = event.range(of: " stop=") {
        lastStopReason = String(event[range.upperBound...])
      }
      TelegramDeliveryLog.record(event, task: key, sessionPath: model.currentSessionPath)
    }
    sessionPathObservations[key] = model.$currentSessionPath
      .sink { [weak self, weak model] path in
        guard let self, let model, !path.isEmpty, self.generation == generation,
          self.pendingModels.contains(modelID)
        else { return }
        self.associate(prompt.messageID, with: model, sessionPath: path)
      }
    var started = false
    let previousSettlement = model.lastSettledTurnID
    replies[key] = model.$isStreaming.combineLatest(model.$lastSettledTurnID).sink {
      [weak self, weak model] streaming, settlement in
      if streaming {
        if !started { log("streaming_started") }
        started = true
        return
      }
      // A short Server-owned turn can finish between desktop polls. Its native
      // terminal identity must complete delivery even without a running snapshot.
      guard started || (settlement != nil && settlement != previousSettlement) else { return }
      log("streaming_stopped")
      Task { @MainActor [weak self, weak model] in
        guard let self, self.generation == generation, let model else { return }
        guard self.replies.removeValue(forKey: key) != nil else { return }
        model.onTelegramLifecycleEvent = nil
        // Let an initial card send finish; it will render the recorded terminal state.
        if self.progressCards[key] != nil { self.progressTasks.removeValue(forKey: key)?.cancel() }
        self.sessionPathObservations.removeValue(forKey: key)
        self.associate(prompt.messageID, with: model)
        if let project = model.projectURL?.standardizedFileURL.path,
          self.remoteModels[project] === model
        {
          self.rememberSession(model)
        }
        self.workspace?.remoteSessionChanged(
          in: model.projectURL, sessionPath: model.currentSessionPath)
        let elapsed = Self.progressElapsed(startedAt: startedAt)
        let output = Self.latestReply(in: model.messages, excluding: existing)
        let outcome = TelegramPresentation.taskOutcome(
          stopReason: model.terminalStopReason ?? lastStopReason, hasReply: output != nil)
        let error = model.messages.last {
          !existing.contains($0.id) && $0.kind == .system && $0.isError
        }?.text
        let project = model.projectURL?.standardizedFileURL.path
        let textReply = TelegramPresentation.resultText(
          outcome: outcome, reply: output, error: error)
        var text = textReply
        if let project {
          var files: [URL] = []
          for path in Self.outputFiles(in: output ?? "").prefix(30) {
            guard
              let url = try? Self.validOutputFile(
                path, projectPath: project,
                modifiedSince: startedAt), !files.contains(url)
            else { continue }
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
        self.recordCompletion(
          key: key, model: model, outcome: outcome, elapsed: elapsed, delivered: nil)
        // A newer successful response must not discard an older undelivered reply.
        self.sendingReplies += 1
        defer { self.sendingReplies -= 1 }
        var delivered = false
        self.inFlightReplyIDs.insert(key)
        defer { self.inFlightReplyIDs.remove(key) }
        if let project {
          self.unsentReplies[project, default: []].append(
            TelegramUnsentReply(id: key, sessionPath: model.currentSessionPath, text: text))
          TelegramUnsentReplyStore.save(self.unsentReplies, defaults: self.defaults)
        }
        log("send_started", "characters=\(text.count)")
        do {
          try await Self.send(
            text, token: token, userID: userID,
            allowed: { [weak self] in self?.generation == generation },
            onSent: { [weak self, weak model] id in
              guard let self, self.generation == generation else { return }
              self.associate(id, with: model)
              if let project,
                let index = self.unsentReplies[project]?.firstIndex(where: { $0.id == key })
              {
                self.unsentReplies[project]![index].deliveredChunks =
                  (self.unsentReplies[project]![index].deliveredChunks ?? 0) + 1
                TelegramUnsentReplyStore.save(self.unsentReplies, defaults: self.defaults)
              }
            })
          delivered = true
          if self.generation == generation, let project {
            self.unsentReplies[project]?.removeAll { $0.id == key }
            if self.unsentReplies[project]?.isEmpty == true {
              self.unsentReplies.removeValue(forKey: project)
            }
            TelegramUnsentReplyStore.save(self.unsentReplies, defaults: self.defaults)
          }
          log("send_succeeded")
        } catch {
          log("send_failed", "errorType=\(String(describing: type(of: error)))")
          if self.generation == generation {
            if project != nil {
              log("reply_queued_for_retry")
              self.status = "回复发送失败，正在后台重试。"
              self.scheduleReplyRetry(
                token: token, userID: userID, generation: generation, after: error)
            }
          }
        }
        self.progressCards.removeValue(forKey: key)
        if self.generation == generation {
          self.recordCompletion(
            key: key, model: model, outcome: outcome, elapsed: elapsed, delivered: delivered)
          for cardID in self.progressViews.filter({ $0.value == key }).map(\.key) {
            await self.updateCompletedCard(
              key: key, cardID: cardID,
              token: token, userID: userID, generation: generation)
          }
        }
        self.progressContexts.removeValue(forKey: key)
        self.scheduleReplyRetry(token: token, userID: userID, generation: generation)
        self.pendingModels.remove(modelID)
        self.scheduleQueueDrain(for: model)
        // Detaching historical reply views never stops Server-owned runtimes.
        if self.replyModels[model.currentSessionPath] === model,
          self.promptQueues[modelID]?.isEmpty != false,
          !self.pendingModels.contains(modelID),
          self.workspace?.extensionUI.hasPendingRequests(from: model) == false
        {
          if self.workspace?.selectedModel !== model, !self.keepsProcessWarm(model) {
            model.suspendProcess()
          }
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
        self.refreshQueueReceipt(
          sourceMessageID: prompt.messageID,
          text:
            "⚡ 排队任务已提交\n项目  \(TelegramPresentation.compactLabel(model.projectURL?.lastPathComponent ?? "原项目", limit: 32))\n摘要  \(TelegramPresentation.compactLabel(prompt.preview, limit: 48))\n\n进度见状态卡 · 排队取消已失效"
        )
        self.associate(prompt.messageID, with: model)
        self.workspace?.remoteSessionChanged(
          in: model.projectURL, sessionPath: model.currentSessionPath)
        self.startProgress(
          key: key, model: model, token: token, userID: userID,
          generation: generation, startedAt: startedAt)
      }
      guard !accepted, let self, self.generation == generation,
        self.replies.removeValue(forKey: key) != nil
      else { return }
      self.refreshQueueReceipt(
        sourceMessageID: prompt.messageID,
        text: "❌ 提交失败 · 不会自动重交\n请在 Mac 查看错误。")
      model?.onTelegramLifecycleEvent = nil
      self.progressTasks.removeValue(forKey: key)?.cancel()
      self.progressCards.removeValue(forKey: key)
      self.progressContexts.removeValue(forKey: key)
      self.progressViews = self.progressViews.filter { $0.value != key }
      self.sessionPathObservations.removeValue(forKey: key)
      self.pendingModels.remove(modelID)
      if let model { self.scheduleQueueDrain(for: model) }
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation else { return }
        await self.deliverNotice(
          "❌ 提交失败 · 不会自动重交\n请在 Mac 查看错误，点「状态」核实。",
          token: token, userID: userID, generation: generation,
          keyboard: self.keyboard(for: "/status"))
      }
    }
  }

  static func usageMessage(
    accounts: [CodexAccountStatus], gemini: GeminiUsageStatus?, updatedAt: Date?, now: Date = .now,
    page requestedPage: Int = 1
  ) -> String {
    guard !accounts.isEmpty || gemini?.isConfigured == true else {
      return "暂无账户额度数据\n请在 Mac 启用 account-usage 并等待同步。"
    }
    let page = TelegramPresentation.page(
      requestedPage, count: accounts.count, size: TelegramPresentation.accountPageSize)
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
      let warning = remaining.isFinite && remaining <= 15 ? " · ⚠️ 额度偏低" : ""
      return
        "  \(label)  \(TelegramPresentation.percent(remaining))\(resetAt.map { " → \(resetCountdown($0))" } ?? "")\(warning)"
    }
    func geminiLabel(_ window: String?) -> String {
      guard let window else { return "额度" }
      if window.localizedCaseInsensitiveContains("5h")
        || window.localizedCaseInsensitiveContains("five hour")
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
    var lines = [
      "剩余额度 · \(page.number)/\(page.count) 页",
      TelegramPresentation.cacheAge(updatedAt: updatedAt, now: now),
    ]
    if let updatedAt, now.timeIntervalSince(updatedAt) >= 900 {
      lines.append("⚠️ 缓存较旧 · 以实际额度为准")
    }
    if !accounts.isEmpty {
      lines.append(
        "当前 Codex：\(TelegramPresentation.compactLabel(accounts.first(where: \.isActive)?.name ?? "待同步", limit: 32))"
      )
    }
    for (offset, account) in accounts.dropFirst(page.start).prefix(page.end - page.start)
      .enumerated()
    {
      lines.append(
        "\n\(page.start + offset + 1). \(account.isActive ? "●" : "○") Codex \(TelegramPresentation.compactLabel(account.name, limit: 32))\(account.isDefault ? " · 默认" : "")"
      )
      if let error = account.error {
        lines.append("  ⚠️ \(TelegramPresentation.compactLabel(error, limit: 80))")
      } else if account.isHidden {
        lines.append("  额度已隐藏")
      } else {
        if let window = account.primary {
          let label =
            window.windowSeconds.map { $0 <= 21_600 ? "\(Int(($0 / 3_600).rounded()))h" : "7d" }
            ?? "额度"
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
    if page.number == 1, let gemini, gemini.isConfigured {
      lines.append("\n\(gemini.isActive ? "●" : "○") Gemini")
      if let error = gemini.error {
        lines.append("  ⚠️ \(TelegramPresentation.compactLabel(error, limit: 80))")
      } else if gemini.quotas.isEmpty {
        lines.append("  暂无额度数据")
      } else {
        for quota in gemini.quotas {
          lines.append(quotaLine(geminiLabel(quota.window), quota.remainingPercent, quota.resetAt))
        }
      }
    }
    if page.number > 1, gemini?.isConfigured == true { lines.append("\nGemini 额度在第 1 页") }
    lines.append("\n● 当前账户 · 空闲时可切换\n仅本地缓存，不主动刷新额度。")
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
    let root = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
      .resolvingSymlinksInPath()
    let candidate =
      path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
    guard url.path.hasPrefix(root.path + "/"),
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
      ]),
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
    messages.last {
      !existing.contains($0.id) && $0.kind == .assistant
        && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }?.text
  }

  static func statusMessage(
    project: String, session: String, sessionPath: String = "", firstPrompt: String? = nil,
    connection: ConnectionState, busy: Bool, loading: Bool, detail: String,
    model: String = "", thinking: String = "", contextPercent: Double? = nil,
    account: String? = nil, queuedCount: Int = 0, elapsed: String? = nil,
    waitingForConfirmation: Bool = false
  ) -> String {
    let state: String
    switch connection {
    case .connected:
      state =
        waitingForConfirmation
        ? "⏸ 等待 Mac 确认"
        : loading ? "⏳ 加载中" : (busy ? "⚡ 执行中" : "✅ 就绪")
    case .connecting: state = "⏳ 连接中"
    case .disconnected: state = "未连接"
    case .failed(let reason):
      state = "连接失败 · \(TelegramPresentation.compactLabel(reason, limit: 64))"
    }
    let prompt = firstPrompt?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
    let title =
      !session.isEmpty
      ? session
      : !prompt.isEmpty
        ? String(prompt.prefix(50))
        : sessionPath.isEmpty || (connection == .connected && !loading)
          ? "新会话"
          : "会话"
    let compactTitle = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let displayTitle =
      compactTitle.count > 32 ? String(compactTitle.prefix(32)) + "…" : compactTitle
    // A session's file name is stable across restarts. Show its suffix so two untitled
    // conversations with similar first prompts are still distinguishable.
    let fileID = String(
      URL(fileURLWithPath: sessionPath).deletingPathExtension().lastPathComponent.suffix(12))
    let sessionLabel =
      sessionPath.isEmpty
      ? (connection == .connected ? displayTitle : "待连接")
      : "\(displayTitle) · #\(fileID)"
    let contextLabel = contextPercent.map { TelegramPresentation.percent($0) } ?? "待统计"
    var lines = [
      state,
      "项目  \(TelegramPresentation.compactLabel(project, limit: 32))",
      "会话  \(sessionLabel)",
    ]
    if let elapsed { lines.append("耗时  \(elapsed)") }
    if queuedCount > 0 { lines.append("排队  \(queuedCount) 条") }
    lines += [
      "",
      "模型  \(model.isEmpty ? "待加载" : TelegramPresentation.compactLabel(model, limit: 44, preserveSuffix: true))",
      "推理  \(model.isEmpty || thinking.isEmpty ? "待加载" : thinking)",
      "账户  \(TelegramPresentation.compactLabel(account ?? "待同步", limit: 32))",
      "上下文  \(contextLabel)\(contextPercent.map { $0.isFinite && $0 >= 85 ? " · ⚠️ 占用较高" : "" } ?? "")",
    ]
    if waitingForConfirmation {
      lines.append("\n请在 Mac 处理扩展确认。")
    }
    let detail = TelegramPresentation.compactLabel(detail, limit: 80)
    // Skip redundant runtime labels; keep actionable detail and provider errors.
    if !detail.isEmpty && detail != "就绪" && detail != "正在执行" && detail != "已连接" {
      lines.append("\n\(detail)")
    }
    lines.append("\n↩ 回复此卡 → 此会话，不改默认选择")
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
    try await downloadFile(
      fileID: photo.fileID, token: token, localName: "photo.jpg", mimeType: "image/jpeg")
  }

  private static func downloadDocument(_ document: TelegramUpdate.Document, token: String)
    async throws
    -> PromptAttachment
  {
    try await downloadFile(
      fileID: document.fileID, token: token,
      localName: safeDocumentName(document.fileName), mimeType: nil)
  }

  /// Telegram filenames are untrusted; never use path separators or control characters
  /// when saving to the temporary directory or embedding the resulting path in a prompt.
  nonisolated static func safeDocumentName(_ fileName: String?) -> String {
    let name =
      (fileName ?? "file").split(separator: "/", omittingEmptySubsequences: false).last.map(
        String.init) ?? "file"
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    let safe = String(
      String.UnicodeScalarView(
        name.unicodeScalars.map {
          allowed.contains($0) ? $0 : "_"
        }))
    let ext = (safe as NSString).pathExtension
    let suffix = !ext.isEmpty && ext.count <= 12 && ext.allSatisfy(\.isASCII) ? ".\(ext)" : ""
    let base = suffix.isEmpty ? safe : String(safe.dropLast(suffix.count))
    let prefix = String(base.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return (prefix.isEmpty ? "file" : prefix) + suffix
  }

  private static func downloadFile(
    fileID: String, token: String, localName: String, mimeType: String?
  ) async throws
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
      !data.isEmpty, data.count <= maxFileBytes
    else { throw APIError.failed }
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("pi-telegram-\(UUID().uuidString)-\(localName)")
    try data.write(to: destination, options: .atomic)
    return PromptAttachment(url: destination, mimeType: mimeType)
  }

  static func chunks(_ text: String, limit: Int = 3500) -> [String] {
    TelegramDelivery.chunks(text, limit: limit)
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
    body.append(
      Data(
        "--\(boundary)\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n\(userID)\r\n"
          .utf8))
    body.append(
      Data(
        "--\(boundary)\r\nContent-Disposition: form-data; name=\"document\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
          .utf8))
    body.append(data)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 90
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    let (responseData, response) = try await URLSession.shared.data(for: request)
    let _: SentMessage = try TelegramAPI.decode(
      SentMessage.self, data: responseData, response: response, method: "sendDocument")
  }

  @discardableResult
  private static func send(
    _ text: String, token: String, userID: Int64,
    keyboard: [[[String: String]]]? = nil, startingAt: Int = 0,
    allowed: () -> Bool = { true }, onSent: ((Int64) -> Void)? = nil
  ) async throws -> Int64? {
    try await TelegramDelivery.send(
      text, token: token, userID: userID, keyboard: keyboard,
      startingAt: startingAt, allowed: allowed, onSent: onSent)
  }
  /// Update only a known command card; fall back to a new card if editing fails.
  private static func editOrSend(
    _ text: String, token: String, userID: Int64, messageID: Int64?,
    keyboard: [[[String: String]]]? = nil
  ) async throws -> Int64? {
    try await TelegramDelivery.editOrSend(
      text, token: token, userID: userID,
      messageID: messageID, keyboard: keyboard)
  }

  private typealias SentMessage = TelegramAPI.SentMessage
  private typealias APIError = TelegramAPIError

  private static func call<T: Decodable>(token: String, method: String, body: [String: Any])
    async throws -> T
  {
    try await TelegramAPI.call(token: token, method: method, body: body)
  }
}

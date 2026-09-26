import XCTest

@testable import PiMacApp

final class TelegramControlTests: XCTestCase {
  @MainActor
  func testRemoteModelPreferenceDoesNotReadDesktopSelection() {
    let suite = "PiMac.TelegramModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("desktop/model", forKey: "lastSelectedModelID")
    XCTAssertEqual(AppModel.preferredNewSessionModelID(
      currentModelID: "telegram/default", defaults: defaults,
      preferenceKey: "telegram.selectedModelID"), "telegram/default")
    defaults.set("telegram/selected", forKey: "telegram.selectedModelID")
    XCTAssertEqual(AppModel.preferredNewSessionModelID(
      currentModelID: "telegram/default", defaults: defaults,
      preferenceKey: "telegram.selectedModelID"), "telegram/selected")
    XCTAssertEqual(defaults.string(forKey: "lastSelectedModelID"), "desktop/model")
  }

  func testRemotePromptsWaitInFIFOOrderAndRespectQueueLimit() {
    var queue = TelegramPromptQueue<String>()
    XCTAssertEqual(queue.append("first", maxCount: 2), 1)
    XCTAssertEqual(queue.append("second", maxCount: 2), 2)
    XCTAssertNil(queue.append("third", maxCount: 2))
    XCTAssertEqual(queue.removeFirst(), "first")
    XCTAssertEqual(queue.append("third", maxCount: 2), 2)
    XCTAssertEqual(queue.removeFirst(), "second")
    XCTAssertEqual(queue.removeFirst(), "third")
    XCTAssertNil(queue.removeFirst())
  }

  func testTokenStoredLocallyAndCleared() {
    let suite = "PiMac.TelegramControlTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    XCTAssertEqual(TelegramTokenStore.load(defaults: defaults), "")
    TelegramTokenStore.save("123:secret", defaults: defaults)
    XCTAssertEqual(TelegramTokenStore.load(defaults: defaults), "123:secret")
    XCTAssertEqual(defaults.string(forKey: "telegram.botToken"), "123:secret")
    TelegramTokenStore.save("", defaults: defaults)
    XCTAssertEqual(TelegramTokenStore.load(defaults: defaults), "")
    XCTAssertNil(defaults.object(forKey: "telegram.botToken"))
  }

  private func update(
    user: Int64 = 42, chat: Int64 = 42, type: String = "private",
    bot: Bool = false, date: Int = 200
  ) throws -> TelegramUpdate {
    let data = try JSONSerialization.data(withJSONObject: [
      "update_id": 1,
      "message": [
        "date": date, "from": ["id": user, "is_bot": bot],
        "chat": ["id": chat, "type": type], "text": "/status",
      ],
    ])
    return try JSONDecoder().decode(TelegramUpdate.self, from: data)
  }

  func testOnlyAllowlistedPrivateSenderIsAuthorized() throws {
    let since = Date(timeIntervalSince1970: 100)
    XCTAssertEqual(try update().authorizedText(userID: 42, since: since), "/status")
    XCTAssertNil(try update(user: 43).authorizedText(userID: 42, since: since))
    XCTAssertNil(try update(chat: 43).authorizedText(userID: 42, since: since))
    XCTAssertNil(try update(type: "group").authorizedText(userID: 42, since: since))
    XCTAssertNil(try update(bot: true).authorizedText(userID: 42, since: since))
    XCTAssertNil(try update(date: 99).authorizedText(userID: 42, since: since))
  }

  func testPhotoOnlyAndCaptionedMessagesRequireAuthorizedPrivateSender() throws {
    func photoUpdate(user: Int64 = 42, chat: Int64 = 42, type: String = "private",
                     bot: Bool = false, date: Int = 200, caption: String? = nil) throws -> TelegramUpdate {
      var message: [String: Any] = [
        "date": date, "from": ["id": user, "is_bot": bot],
        "chat": ["id": chat, "type": type],
        "photo": [["file_id": "small", "file_size": 100],
                  ["file_id": "large", "file_size": 200]],
      ]
      message["caption"] = caption
      let data = try JSONSerialization.data(withJSONObject: ["update_id": 2, "message": message])
      return try JSONDecoder().decode(TelegramUpdate.self, from: data)
    }
    let since = Date(timeIntervalSince1970: 100)
    XCTAssertEqual(try photoUpdate().authorizedMessage(userID: 42, since: since)?.photo?.last?.fileID, "large")
    XCTAssertNil(try photoUpdate().authorizedText(userID: 42, since: since))
    XCTAssertEqual(try photoUpdate(caption: "解释图片").authorizedMessage(userID: 42, since: since)?.caption, "解释图片")
    XCTAssertNil(try photoUpdate(user: 43).authorizedMessage(userID: 42, since: since))
    XCTAssertNil(try photoUpdate(chat: 43).authorizedMessage(userID: 42, since: since))
    XCTAssertNil(try photoUpdate(type: "group").authorizedMessage(userID: 42, since: since))
    XCTAssertNil(try photoUpdate(bot: true).authorizedMessage(userID: 42, since: since))
    XCTAssertNil(try photoUpdate(date: 99).authorizedMessage(userID: 42, since: since))
  }

  @MainActor
  func testStatusCardOmitsEmptyDetailAndShowsMeaningfulState() {
    let ready = TelegramControl.statusMessage(
      project: "demo", session: "", connection: .connected, busy: false,
      loading: false, detail: "  ")
    XCTAssertTrue(ready.contains("📁 项目  demo"))
    XCTAssertTrue(ready.contains("💬 会话  新会话"))
    XCTAssertTrue(ready.contains("🤖 模型  待加载"))
    XCTAssertTrue(ready.contains("🧠 推理强度  待加载"))
    XCTAssertTrue(ready.contains("📊 上下文  待统计"))
    let configured = TelegramControl.statusMessage(
      project: "demo", session: "", connection: .connected, busy: false,
      loading: false, detail: "", model: "anthropic/claude", thinking: "high",
      contextPercent: 82.6)
    XCTAssertTrue(configured.contains("📊 上下文  83%"))
    XCTAssertTrue(TelegramControl.statusMessage(
      project: "demo", session: "", connection: .connected, busy: false,
      loading: false, detail: "", contextPercent: .nan).contains("📊 上下文  待统计"))
    XCTAssertTrue(configured.contains("🤖 模型  anthropic/claude"))
    XCTAssertTrue(configured.contains("🧠 推理强度  high"))
    XCTAssertTrue(configured.contains("👤 Codex 账户  待同步"))
    XCTAssertTrue(TelegramControl.statusMessage(
      project: "demo", session: "", connection: .connected, busy: false,
      loading: false, detail: "", account: "work").contains("👤 Codex 账户  work"))
    XCTAssertTrue(ready.contains("✅ 就绪，可以发送任务"))
    XCTAssertFalse(ready.contains("ℹ️"))
    let busy = TelegramControl.statusMessage(
      project: "demo", session: "任务", connection: .connected, busy: true,
      loading: false, detail: "等待工具执行")
    XCTAssertTrue(busy.contains("⚡ 正在执行"))
    XCTAssertTrue(busy.contains("ℹ️ 等待工具执行"))
    let disconnected = TelegramControl.statusMessage(
      project: "demo", session: "", connection: .disconnected, busy: false,
      loading: false, detail: "")
    XCTAssertTrue(disconnected.contains("💬 会话  待连接"))
    XCTAssertFalse(disconnected.contains("新会话"))
    let newSession = TelegramControl.statusMessage(
      project: "demo", session: "", sessionPath: "/tmp/session-123456789abc.jsonl",
      connection: .connected, busy: false, loading: false, detail: "")
    XCTAssertTrue(newSession.contains("💬 会话  新会话 · #123456789abc"))
    let existing = TelegramControl.statusMessage(
      project: "demo", session: "", sessionPath: "/tmp/session-abcdef123456.jsonl",
      firstPrompt: "查找问题", connection: .connected, busy: false, loading: false, detail: "")
    XCTAssertTrue(existing.contains("💬 会话  查找问题 · #abcdef123456"))
    let named = TelegramControl.statusMessage(
      project: "demo", session: "任务", sessionPath: "/tmp/session-abcdef123456.jsonl",
      firstPrompt: "查找问题", connection: .connected, busy: false, loading: false, detail: "")
    XCTAssertTrue(named.contains("💬 会话  任务 · #abcdef123456"))
    let disconnectedSession = TelegramControl.statusMessage(
      project: "demo", session: "", sessionPath: "/tmp/session-abcdef123456.jsonl",
      connection: .disconnected, busy: false, loading: false, detail: "")
    XCTAssertTrue(disconnectedSession.contains("💬 会话  会话 · #abcdef123456"))
    XCTAssertTrue(TelegramControl.statusMessage(
      project: "demo", session: "", connection: .failed("断开"), busy: false,
      loading: false, detail: "").contains("🔴 连接失败：断开"))
  }

  @MainActor
  func testFirstStatusWaitsForRemoteConnection() async {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    var completed = false
    let waiting = Task {
      await TelegramControl.waitForSessionStatus(in: model)
      completed = true
    }
    model.connectionState = .connecting
    model.isLoadingConfiguration = true
    try? await Task.sleep(for: .milliseconds(150))
    XCTAssertFalse(completed)
    model.connectionState = .connected
    model.isLoadingConfiguration = false
    await waiting.value
    XCTAssertTrue(completed)
  }

  @MainActor
  func testInitialPromptWaitsForConfigurationAfterConnection() async {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.connectionState = .connecting
    model.isLoadingConfiguration = true
    var finished = false
    let waiting = Task {
      await TelegramControl.waitForSessionStatus(in: model)
      finished = true
    }
    model.connectionState = .connected
    try? await Task.sleep(for: .milliseconds(150))
    XCTAssertFalse(finished, "RPC connected before initial model configuration is ready")
    model.isLoadingConfiguration = false
    await waiting.value
    XCTAssertTrue(finished)
  }

  @MainActor
  func testLatestReplyIgnoresHistoryAndSystemMessages() {
    let old = ChatEntry(id: "old", kind: .assistant, title: "助手", text: "旧回复")
    let first = ChatEntry(id: "first", kind: .assistant, title: "助手", text: "第一段")
    let second = ChatEntry(id: "second", kind: .assistant, title: "助手", text: "最终回复")
    let system = ChatEntry(id: "system", kind: .system, title: "系统", text: "系统提示")
    XCTAssertEqual(TelegramControl.latestReply(
      in: [old, first, second, system], excluding: ["old"]), "最终回复")
    XCTAssertNil(TelegramControl.latestReply(in: [old, system], excluding: ["old"]))
  }

  @MainActor
  func testBotMenuRegistersSupportedCommands() {
    XCTAssertEqual(
      TelegramControl.botCommands.compactMap { $0["command"] },
      ["projects", "sessions", "status", "model", "thinking", "usage", "accounts", "new", "compact", "stop", "last", "help"])
    XCTAssertTrue(TelegramControl.botCommands.allSatisfy { !$0["description", default: ""].isEmpty })
  }

  @MainActor
  func testHelpGroupsCommandsAndExplainsHowToStart() {
    let help = TelegramControl.help
    XCTAssertTrue(help.contains("先用 /projects 下方的按钮选项目，随后会自动显示会话状态"))
    XCTAssertTrue(help.contains("发送文本或照片（可附说明）"))
    XCTAssertTrue(help.contains("/compact  空闲时压缩当前会话上下文"))
    XCTAssertTrue(help.contains("📁 项目与会话"))
    XCTAssertTrue(help.contains("⚙️ 设置与额度"))
    XCTAssertTrue(help.contains("⏹ 任务与回复"))
    for command in TelegramControl.botCommands.compactMap({ $0["command"] }) {
      XCTAssertTrue(help.contains("/\(command) "), "帮助缺少 /\(command)")
    }
    XCTAssertTrue(help.contains("扩展确认仍需在 Mac 上完成"))
  }

  @MainActor
  func testIdleModelCanRestartButQueuedPromptsCannot() {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    XCTAssertTrue(model.canRestartSafely)
    model.queuedPrompts = [QueuedPrompt(id: UUID(), text: "pending", rpcText: "pending", delivery: .steer, attachments: [])]
    XCTAssertFalse(model.canRestartSafely)
  }

  @MainActor
  func testPollingSubscribesToButtonCallbacks() {
    XCTAssertTrue(TelegramControl.allowedUpdates.contains("message"))
    XCTAssertTrue(TelegramControl.allowedUpdates.contains("callback_query"))
  }

  func testCallbackRequiresAllowlistedPrivateSenderAndKnownAction() throws {
    func callback(user: Int64 = 42, chat: Int64 = 42, type: String = "private",
                  bot: Bool = false, command: String = "/projects") throws -> TelegramUpdate {
      let data = try JSONSerialization.data(withJSONObject: [
        "update_id": 3,
        "callback_query": [
          "id": "callback-1", "from": ["id": user, "is_bot": bot],
          "message": ["chat": ["id": chat, "type": type]], "data": command,
        ],
      ])
      return try JSONDecoder().decode(TelegramUpdate.self, from: data)
    }
    XCTAssertEqual(try callback().authorizedCallback(userID: 42)?.command, "/projects")
    XCTAssertEqual(try callback(command: "select:2").authorizedCallback(userID: 42)?.id, "callback-1")
    XCTAssertEqual(try callback(command: "/projects 2").authorizedCallback(userID: 42)?.id, "callback-1")
    XCTAssertEqual(try callback(command: "/sessions").authorizedCallback(userID: 42)?.command, "/sessions")
    XCTAssertEqual(try callback(command: "/sessions 2").authorizedCallback(userID: 42)?.command, "/sessions 2")
    let sessionAction = "session:\(UUID().uuidString)"
    XCTAssertEqual(try callback(command: sessionAction).authorizedCallback(userID: 42)?.command, sessionAction)
    XCTAssertLessThanOrEqual(sessionAction.utf8.count, 64)
    XCTAssertNil(try callback(command: "session:1").authorizedCallback(userID: 42))
    XCTAssertNil(try callback(command: "/sessions 0").authorizedCallback(userID: 42))
    XCTAssertNil(try callback(command: "/sessions -1").authorizedCallback(userID: 42))
    XCTAssertNil(try callback(user: 43, command: sessionAction).authorizedCallback(userID: 42))
    XCTAssertEqual(try callback(command: "/usage").authorizedCallback(userID: 42)?.command, "/usage")
    XCTAssertEqual(try callback(command: "/accounts").authorizedCallback(userID: 42)?.command, "/accounts")
    XCTAssertEqual(try callback(command: "account:2").authorizedCallback(userID: 42)?.command, "account:2")
    XCTAssertNil(try callback(command: "account:0").authorizedCallback(userID: 42))
    XCTAssertEqual(try callback(command: "/compact").authorizedCallback(userID: 42)?.command, "/compact")
    XCTAssertEqual(try callback(command: "/model 2").authorizedCallback(userID: 42)?.command, "/model 2")
    XCTAssertEqual(try callback(command: "model:21").authorizedCallback(userID: 42)?.command, "model:21")
    XCTAssertEqual(try callback(command: "thinking:xhigh").authorizedCallback(userID: 42)?.command, "thinking:xhigh")
    XCTAssertNil(try callback(command: "model:0").authorizedCallback(userID: 42))
    XCTAssertNil(try callback(command: "thinking:invalid").authorizedCallback(userID: 42))
    XCTAssertNil(try callback(user: 43).authorizedCallback(userID: 42))
    XCTAssertNil(try callback(chat: 43).authorizedCallback(userID: 42))
    XCTAssertNil(try callback(type: "group").authorizedCallback(userID: 42))
    XCTAssertNil(try callback(bot: true).authorizedCallback(userID: 42))
    XCTAssertNil(try callback(command: "select:0").authorizedCallback(userID: 42))
    XCTAssertNil(try callback(command: "/project 2").authorizedCallback(userID: 42))
    XCTAssertNil(try callback(command: "run a task").authorizedCallback(userID: 42))
    XCTAssertNil(try callback(command: "/unknown").authorizedCallback(userID: 42))
    XCTAssertNil(try callback().authorizedText(userID: 42, since: .distantPast))
  }

  func testUpdatesWithoutMessagesAreIgnored() throws {
    let update = try JSONDecoder().decode(TelegramUpdate.self, from: Data(#"{"update_id":2}"#.utf8))
    XCTAssertNil(update.authorizedText(userID: 42, since: .distantPast))
  }

  @MainActor
  func testRemotePromptRejectsDisconnectedSessionWithoutChangingDraft() {
    let model = AppModel(restoreLastProjectOnLaunch: false, initialComposerText: "local draft")
    var accepted: Bool?
    model.sendRemotePrompt("remote task") { accepted = $0 }
    XCTAssertEqual(accepted, false)
    XCTAssertEqual(model.composerText, "local draft")
    XCTAssertTrue(model.messages.isEmpty)
  }

  @MainActor
  func testSessionListTitlesAreCompact() {
    XCTAssertEqual(TelegramControl.sessionListTitle(name: "My session", firstPrompt: "ignored"), "My session")
    XCTAssertEqual(TelegramControl.sessionListTitle(name: "  ", firstPrompt: "Fix\n the  bug"), "Fix the bug")
    XCTAssertEqual(TelegramControl.sessionListTitle(name: "", firstPrompt: nil), "新会话")
    XCTAssertEqual(TelegramControl.sessionListTitle(name: "", firstPrompt: "  "), "新会话")
    XCTAssertEqual(TelegramControl.sessionListTitle(name: String(repeating: "长", count: 200), firstPrompt: nil).count, 100)
  }

  @MainActor
  func testUsageMessageFormatsQuotasAndMissingExtension() {
    XCTAssertTrue(TelegramControl.usageMessage(accounts: [], gemini: nil, updatedAt: nil).contains("暂无账户额度数据"))
    let account = CodexAccountStatus(
      name: "work", isActive: true, isDefault: false, isHidden: false,
      primary: CodexUsageWindow(remainingPercent: 72.5, resetAt: Date(timeIntervalSince1970: 1_800_000_000), windowSeconds: 18_000),
      secondary: nil, resetCredits: nil, error: nil)
    let gemini = GeminiUsageStatus(
      isConfigured: true, isActive: false,
      quotas: [GeminiQuota(remainingPercent: 25, resetAt: nil, window: "5h")], error: nil)
    let message = TelegramControl.usageMessage(accounts: [account], gemini: gemini, updatedAt: nil)
    XCTAssertTrue(message.contains("● Codex work"))
    XCTAssertTrue(message.contains("  5h  73% → "))
    XCTAssertTrue(message.contains("○ Gemini"))
    XCTAssertTrue(message.contains("  5h  25%"))
    XCTAssertFalse(message.contains("重置于"))
  }

  @MainActor
  func testUsageMessageShowsTimeUntilReset() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let cases: [(TimeInterval, String)] = [
      (1, "1分钟后刷新"),
      (60, "1分钟后刷新"),
      (61, "2分钟后刷新"),
      (3_600, "1小时后刷新"),
      (8_100, "2小时15分钟后刷新"),
      (86_400, "1天后刷新"),
      (183_780, "2天3小时3分钟后刷新"),
      (0, "已到刷新时间"),
      (-60, "已到刷新时间"),
    ]
    for (interval, expected) in cases {
      let resetAt = now.addingTimeInterval(interval)
      let window = CodexUsageWindow(remainingPercent: 87, resetAt: resetAt, windowSeconds: 18_000)
      let account = CodexAccountStatus(
        name: "work", isActive: true, isDefault: false, isHidden: false,
        primary: window, secondary: window, resetCredits: nil, error: nil)
      let gemini = GeminiUsageStatus(isConfigured: true, isActive: false,
        quotas: [GeminiQuota(remainingPercent: 100, resetAt: resetAt, window: "7d")], error: nil)
      let message = TelegramControl.usageMessage(
        accounts: [account], gemini: gemini, updatedAt: now, now: now)
      XCTAssertTrue(message.contains("5h  87% → \(expected)"), message)
      XCTAssertTrue(message.contains("7d  87% → \(expected)"), message)
      XCTAssertTrue(message.contains("7d  100% → \(expected)"), message)
      XCTAssertTrue(message.contains("\n更新 "))
    }
  }

  @MainActor
  func testUsageMessageShortensVerboseGeminiWindows() {
    let gemini = GeminiUsageStatus(isConfigured: true, isActive: true, quotas: [
      GeminiQuota(remainingPercent: 100, resetAt: nil, window: "5h Five Hour Limit Remaining"),
      GeminiQuota(remainingPercent: 80, resetAt: nil, window: "weekly Weekly Limit Remaining"),
    ], error: nil)
    let message = TelegramControl.usageMessage(accounts: [], gemini: gemini, updatedAt: nil)
    XCTAssertTrue(message.contains("  5h  100%"))
    XCTAssertTrue(message.contains("  7d  80%"))
    XCTAssertFalse(message.contains("Limit Remaining"))
  }

  @MainActor
  func testLongRepliesPreserveUnicodeAndStayWithinLimit() {
    let text = String(repeating: "你好👩🏽‍💻e\u{301}\n", count: 1000)
    let chunks = TelegramControl.chunks(text)
    XCTAssertGreaterThan(chunks.count, 1)
    XCTAssertEqual(chunks.joined(), text)
    XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.utf16.count <= 3500 })
    XCTAssertEqual(TelegramControl.chunks(""), [])
    XCTAssertEqual(TelegramControl.chunks("hello"), ["hello"])
  }
}

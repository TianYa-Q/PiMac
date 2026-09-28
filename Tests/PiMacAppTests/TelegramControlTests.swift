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

  @MainActor
  func testProjectListOnlyShowsNames() {
    let projects = [WorkspaceProject(url: URL(fileURLWithPath: "/private/projects/first")),
                    WorkspaceProject(url: URL(fileURLWithPath: "/private/projects/second"))]
    XCTAssertEqual(TelegramControl.projectList(projects[...], start: 0), "1. first\n2. second")
    XCTAssertEqual(TelegramControl.projectList(projects[1...], start: 1), "2. second")
  }

  @MainActor
  func testQuotedSessionSticksForFollowingUnquotedTextAndImages() {
    let suite = "PiMac.TelegramRoutingTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var sessions = TelegramMessageSessionStore(defaults: defaults)
    let project3 = TelegramMessageSessionStore.Location(
      project: "/projects/three", sessionPath: "/sessions/three.jsonl")
    let project2 = TelegramMessageSessionStore.Location(
      project: "/projects/two", sessionPath: "/sessions/two.jsonl")
    sessions.remember(10, location: project3, defaults: defaults)
    sessions.remember(20, location: project2, defaults: defaults)
    let pinned = TelegramControl.routeLocation(replyToID: 10, sessions: sessions, active: nil)
    XCTAssertEqual(pinned, project3)
    // Attachment and text messages share the same route when neither quotes a message.
    XCTAssertEqual(TelegramControl.routeLocation(replyToID: nil, sessions: sessions, active: pinned), project3)
    XCTAssertEqual(TelegramControl.routeLocation(replyToID: 20, sessions: sessions, active: pinned), project2)
    XCTAssertNil(TelegramControl.routeLocation(replyToID: 999, sessions: sessions, active: pinned))
    XCTAssertNil(TelegramControl.routeLocation(replyToID: nil, sessions: sessions, active: nil))
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

  func testUndeliveredRepliesSurviveReloadAndCanBeCleared() {
    let suite = "PiMac.TelegramRepliesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let reply = TelegramUnsentReply(id: UUID(), sessionPath: "/tmp/session.jsonl", text: "未送达的回复")

    XCTAssertTrue(TelegramUnsentReplyStore.load(defaults: defaults).isEmpty)
    let next = TelegramUnsentReply(id: UUID(), sessionPath: "/tmp/next.jsonl", text: "第二条")
    TelegramUnsentReplyStore.save(["/tmp/project": [reply, next]], defaults: defaults)
    XCTAssertEqual(TelegramUnsentReplyStore.load(defaults: defaults)["/tmp/project"], [reply, next])
    TelegramUnsentReplyStore.save([:], defaults: defaults)
    XCTAssertTrue(TelegramUnsentReplyStore.load(defaults: defaults).isEmpty)
    XCTAssertNil(defaults.data(forKey: "telegram.unsentReplies"))
  }

  func testNewProjectFilesLinkedInReplyCanBeDeliveredWithoutPromptInstructions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("telegram-output-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("report.txt")
    try Data("ok".utf8).write(to: file)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("telegram-outside-\(UUID().uuidString)")
    try Data("private".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    let link = root.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    let parsed = TelegramControl.outputFiles(in:
      "已完成：[报告](report.txt)，路径 `report.txt`，以及 [网页](https://example.com)。")
    XCTAssertEqual(parsed, ["report.txt"])
    XCTAssertEqual(TelegramControl.outputFiles(in: "修改了 `Sources/AppModel.swift`"), [])
    XCTAssertEqual(TelegramControl.outputFiles(in: "[下载](file://\(file.path))"), [file.path])
    XCTAssertEqual(TelegramControl.outputFiles(in: "[报告](report%2Etxt)"), ["report.txt"])
    XCTAssertEqual(try TelegramControl.validOutputFile("report.txt", projectPath: root.path,
      modifiedSince: Date(timeIntervalSinceNow: -10)).path, file.path)
    XCTAssertThrowsError(try TelegramControl.validOutputFile("report.txt", projectPath: root.path,
      modifiedSince: Date(timeIntervalSinceNow: 10)))
    XCTAssertThrowsError(try TelegramControl.validOutputFile("../\(outside.lastPathComponent)", projectPath: root.path))
    XCTAssertThrowsError(try TelegramControl.validOutputFile(link.path, projectPath: root.path))
    XCTAssertThrowsError(try TelegramControl.validOutputFile("missing.txt", projectPath: root.path))
    XCTAssertEqual(TelegramControl.outputFiles(in: "普通文本 report.txt"), [])
  }

  func testGeneratedFileQueuePersists() {
    let suite = "PiMac.TelegramFilesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let file = TelegramPendingFile(id: UUID(), projectPath: "/tmp/project", filePath: "/tmp/project/report.pdf")
    TelegramPendingFileStore.save([file], defaults: defaults)
    XCTAssertEqual(TelegramPendingFileStore.load(defaults: defaults), [file])
    TelegramPendingFileStore.save([], defaults: defaults)
    XCTAssertTrue(TelegramPendingFileStore.load(defaults: defaults).isEmpty)
  }

  func testFailedCommandNoticesPersistWithKeyboardsAndPreserveOrder() {
    let suite = "PiMac.TelegramNoticesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = TelegramPendingNotice(
      id: UUID(), text: "已排队（等待队列第 1 位）。",
      keyboard: [[ ["text": "状态", "callback_data": "/status"] ]], sourceMessageID: 123)
    let second = TelegramPendingNotice(id: UUID(), text: "已切换模型", keyboard: nil)
    XCTAssertTrue(TelegramPendingNoticeStore.load(defaults: defaults).isEmpty)
    TelegramPendingNoticeStore.save([first, second], defaults: defaults)
    XCTAssertEqual(TelegramPendingNoticeStore.load(defaults: defaults), [first, second])
    XCTAssertEqual(TelegramPendingNoticeStore.load(defaults: defaults).first?.sourceMessageID, 123)
    TelegramPendingNoticeStore.save([second], defaults: defaults)
    XCTAssertEqual(TelegramPendingNoticeStore.load(defaults: defaults), [second])
    TelegramPendingNoticeStore.save([], defaults: defaults)
    XCTAssertNil(defaults.data(forKey: "telegram.pendingNotices"))
  }

  func testUpdateCursorRestoresBacklogAfterFirstSuccessfulPollAndResetsForNewBot() throws {
    let suite = "PiMac.TelegramCursorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let now = Date(timeIntervalSince1970: 200)
    XCTAssertNil(TelegramUpdateCursorStore.load(defaults: defaults))
    XCTAssertNil(try update(date: 199).authorizedMessage(
      userID: 42, since: TelegramUpdateCursorStore.earliestMessageDate(now: now, defaults: defaults)))

    // Even a poll returning no updates stores 0: subsequent launches accept
    // messages received while the app was closed.
    TelegramUpdateCursorStore.save(0, defaults: defaults)
    XCTAssertEqual(TelegramUpdateCursorStore.load(defaults: defaults), 0)
    XCTAssertNotNil(try update(date: 199).authorizedMessage(
      userID: 42, since: TelegramUpdateCursorStore.earliestMessageDate(now: now, defaults: defaults)))
    TelegramUpdateCursorStore.save(123, defaults: defaults)
    XCTAssertEqual(TelegramUpdateCursorStore.load(defaults: defaults), 123)
    TelegramUpdateCursorStore.clear(defaults: defaults)
    XCTAssertNil(TelegramUpdateCursorStore.load(defaults: defaults))
  }

  func testLegacyUndeliveredReplyMigratesToQueue() throws {
    let suite = "PiMac.TelegramLegacyRepliesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let reply = TelegramUnsentReply(id: UUID(), sessionPath: "/tmp/session.jsonl", text: "旧回复")
    defaults.set(try JSONEncoder().encode(["/tmp/project": reply]), forKey: "telegram.unsentReplies")
    XCTAssertEqual(TelegramUnsentReplyStore.load(defaults: defaults)["/tmp/project"], [reply])
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

  func testReplyMetadataDecodesOnlyForAuthorizedPrivateMessages() throws {
    let json = #"{"update_id":5,"message":{"message_id":102,"reply_to_message":{"message_id":99},"date":200,"from":{"id":42,"is_bot":false},"chat":{"id":42,"type":"private"},"text":"继续"}}"#
    let update = try JSONDecoder().decode(TelegramUpdate.self, from: Data(json.utf8))
    let message = try XCTUnwrap(update.authorizedMessage(userID: 42,
      since: Date(timeIntervalSince1970: 100)))
    XCTAssertEqual(message.messageID, 102)
    XCTAssertEqual(message.replyToMessage?.messageID, 99)
    XCTAssertNil(update.authorizedMessage(userID: 43, since: .distantPast))
  }

  func testReplyAssociationsPersistAreBoundedAndCanBeReset() throws {
    let name = "telegram-replies-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let location = TelegramMessageSessionStore.Location(
      project: "/tmp/project-a", sessionPath: "/tmp/session-a.jsonl")
    var store = TelegramMessageSessionStore(defaults: defaults)
    store.remember(100, location: location, defaults: defaults)
    XCTAssertEqual(TelegramMessageSessionStore(defaults: defaults)[100], location)
    for id in 101...103 {
      store.remember(Int64(id), location: location, defaults: defaults, maxCount: 3)
    }
    XCTAssertNil(store[100])
    XCTAssertEqual(store[103], location)
    XCTAssertEqual(store.entries.count, 3)
    store.clear(defaults: defaults)
    XCTAssertNil(TelegramMessageSessionStore(defaults: defaults)[103])
  }

  func testReplyTargetMustBelongToOriginalProject() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("telegram-target-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("""
      {"type":"session","cwd":"/tmp/project-a"}
      {"type":"message","message":{"role":"user","content":"hello"}}

      """.utf8).write(to: url)
    let root = url.deletingLastPathComponent()
    XCTAssertTrue(AppModel.sessionExists(at: url.path, for: "/tmp/project-a", root: root))
    XCTAssertFalse(AppModel.sessionExists(at: url.path, for: "/tmp/project-b", root: root))
    XCTAssertFalse(AppModel.sessionExists(at: url.path + ".missing", for: "/tmp/project-a", root: root))
    XCTAssertFalse(AppModel.sessionExists(at: url.path, for: "/tmp/project-a",
      root: root.appendingPathComponent("other")))
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

  func testDocumentRequiresAuthorizedPrivateSenderAndSanitizesFilename() throws {
    func documentUpdate(user: Int64 = 42, chat: Int64 = 42,
                        type: String = "private", date: Int = 200) throws -> TelegramUpdate {
      let data = try JSONSerialization.data(withJSONObject: [
        "update_id": 4,
        "message": [
          "date": date, "from": ["id": user, "is_bot": false],
          "chat": ["id": chat, "type": type], "caption": "总结内容",
          "document": ["file_id": "document-1", "file_size": 1234, "file_name": "../../报表\n2026.pdf"],
        ],
      ])
      return try JSONDecoder().decode(TelegramUpdate.self, from: data)
    }
    let since = Date(timeIntervalSince1970: 100)
    let message = try documentUpdate().authorizedMessage(userID: 42, since: since)
    XCTAssertEqual(message?.document?.fileID, "document-1")
    XCTAssertEqual(message?.document?.fileSize, 1234)
    XCTAssertEqual(message?.caption, "总结内容")
    XCTAssertNil(try documentUpdate(user: 43).authorizedMessage(userID: 42, since: since))
    XCTAssertNil(try documentUpdate(chat: 43).authorizedMessage(userID: 42, since: since))
    XCTAssertNil(try documentUpdate(type: "group").authorizedMessage(userID: 42, since: since))
    XCTAssertNil(try documentUpdate(date: 99).authorizedMessage(userID: 42, since: since))
    XCTAssertEqual(TelegramControl.safeDocumentName(message?.document?.fileName), "___2026.pdf")
    XCTAssertEqual(TelegramControl.safeDocumentName("../.env"), "env")
    XCTAssertEqual(TelegramControl.safeDocumentName("..\\evil.txt"), "_evil.txt")
    XCTAssertEqual(TelegramControl.safeDocumentName(nil), "file")
    XCTAssertEqual(TelegramControl.safeDocumentName(String(repeating: "a", count: 100) + ".pdf"),
      String(repeating: "a", count: 60) + ".pdf")
  }

  @MainActor
  func testRemoteFilePromptReferencesFileButImageRemainsInline() {
    let file = PromptAttachment(url: URL(fileURLWithPath: "/tmp/pi-telegram-report.pdf"), mimeType: nil)
    let image = PromptAttachment(url: URL(fileURLWithPath: "/tmp/pi-telegram-photo.jpg"), mimeType: "image/jpeg")
    let prompt = AppModel.rpcText(for: "请分析", attachments: [file, image])
    XCTAssertTrue(prompt.contains("<pi-mac-attached-files>"))
    XCTAssertTrue(prompt.contains(file.url.path))
    XCTAssertFalse(prompt.contains(image.url.path))
    XCTAssertEqual(AppModel.rpcText(for: "请分析", attachments: [image]), "请分析")
    XCTAssertEqual(AppModel.rpcText(for: "生成报告", attachments: []), "生成报告")
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
      ["projects", "sessions", "status", "model", "thinking", "usage", "accounts", "new", "compact", "stop", "help"])
    XCTAssertTrue(TelegramControl.botCommands.allSatisfy { !$0["description", default: ""].isEmpty })
  }

  @MainActor
  func testHelpGroupsCommandsAndExplainsHowToStart() {
    let help = TelegramControl.help
    XCTAssertTrue(help.contains("先用 /projects 下方的按钮选项目，随后会自动显示会话状态"))
    XCTAssertTrue(help.contains("发送文本、照片或文件（可附说明）"))
    XCTAssertTrue(help.contains("/compact  空闲时压缩当前会话上下文"))
    XCTAssertTrue(help.contains("📁 项目与会话"))
    XCTAssertTrue(help.contains("⚙️ 设置与额度"))
    XCTAssertTrue(help.contains("⏹ 任务与回复"))
    for command in TelegramControl.botCommands.compactMap({ $0["command"] }) {
      XCTAssertTrue(help.contains("/\(command) "), "帮助缺少 /\(command)")
    }
    XCTAssertTrue(help.contains("回传失败的回复会在后台自动重试"))
    XCTAssertFalse(help.contains("/last"))
    XCTAssertTrue(help.contains("扩展确认仍需在 Mac 上完成"))
  }

  @MainActor
  func testRunningStatusContainsSessionModelAndUsageInsteadOfOnlyElapsedTime() {
    let status = TelegramControl.statusMessage(
      project: "demo", session: "任务", sessionPath: "/tmp/session-abcdef123456.jsonl",
      connection: .connected, busy: true, loading: false, detail: "正在执行工具",
      model: "openai/codex", thinking: "high", contextPercent: 42, account: "work")
    XCTAssertTrue(status.contains("💬 会话  任务 · #abcdef123456"))
    XCTAssertTrue(status.contains("🤖 模型  openai/codex"))
    XCTAssertTrue(status.contains("🧠 推理强度  high"))
    XCTAssertTrue(status.contains("👤 Codex 账户  work"))
    XCTAssertTrue(status.contains("📊 上下文  42%"))
    XCTAssertTrue(status.contains("⚡ 正在执行"))
    XCTAssertTrue(status.contains("ℹ️ 正在执行工具"))
  }

  @MainActor
  func testProgressElapsedStartsAtSubmissionAndKeepsUpdating() {
    let start = Date(timeIntervalSince1970: 1000)
    XCTAssertEqual(TelegramControl.progressElapsed(startedAt: start, now: start), "0 分 0 秒")
    XCTAssertEqual(TelegramControl.progressElapsed(startedAt: start,
      now: start.addingTimeInterval(8)), "0 分 8 秒")
    XCTAssertEqual(TelegramControl.progressElapsed(startedAt: start,
      now: start.addingTimeInterval(98)), "1 分 38 秒")
    XCTAssertEqual(TelegramControl.progressElapsed(startedAt: start,
      now: start.addingTimeInterval(3661)), "1 小时 1 分 1 秒")
    XCTAssertEqual(TelegramControl.progressElapsed(startedAt: start,
      now: start.addingTimeInterval(-1)), "0 分 0 秒")
  }

  @MainActor
  func testDisconnectedOrFailedSessionRetriesOnlyWhenIdle() {
    XCTAssertTrue(TelegramControl.shouldRetryConnection(
      .disconnected, isLoading: false, canRestart: true))
    XCTAssertTrue(TelegramControl.shouldRetryConnection(
      .failed("Pi 启动超时"), isLoading: false, canRestart: true))
    XCTAssertFalse(TelegramControl.shouldRetryConnection(
      .failed("Pi 启动超时"), isLoading: true, canRestart: true))
    XCTAssertFalse(TelegramControl.shouldRetryConnection(
      .failed("Pi 启动超时"), isLoading: false, canRestart: false))
    XCTAssertFalse(TelegramControl.shouldRetryConnection(
      .connecting, isLoading: false, canRestart: true))
    XCTAssertFalse(TelegramControl.shouldRetryConnection(
      .connected, isLoading: false, canRestart: true))
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

  func testOnlyKnownFunctionalCardsCanBeEdited() {
    let cards: Set<Int64> = [17]
    XCTAssertTrue(TelegramControl.shouldEditCallback(messageID: 17, knownCards: cards, command: "/status"))
    XCTAssertFalse(TelegramControl.shouldEditCallback(messageID: 18, knownCards: cards, command: "/status"))
  }

  func testCallbackRequiresAllowlistedPrivateSenderAndKnownAction() throws {
    func callback(user: Int64 = 42, chat: Int64 = 42, type: String = "private",
                  bot: Bool = false, command: String = "/projects", messageID: Int64? = 17) throws -> TelegramUpdate {
      let data = try JSONSerialization.data(withJSONObject: [
        "update_id": 3,
        "callback_query": [
          "id": "callback-1", "from": ["id": user, "is_bot": bot],
          "message": ["message_id": messageID as Any? ?? NSNull(),
                      "chat": ["id": chat, "type": type]], "data": command,
        ],
      ])
      return try JSONDecoder().decode(TelegramUpdate.self, from: data)
    }
    XCTAssertEqual(try callback().authorizedCallback(userID: 42)?.command, "/projects")
    XCTAssertEqual(try callback().authorizedCallback(userID: 42)?.messageID, 17)
    XCTAssertNil(try callback(messageID: nil).authorizedCallback(userID: 42)?.messageID)
    XCTAssertEqual(try callback(command: "select:2").authorizedCallback(userID: 42)?.id, "callback-1")
    XCTAssertEqual(try callback(command: "/projects 2").authorizedCallback(userID: 42)?.id, "callback-1")
    XCTAssertEqual(try callback(command: "/sessions").authorizedCallback(userID: 42)?.command, "/sessions")
    XCTAssertEqual(try callback(command: "/sessions 2").authorizedCallback(userID: 42)?.command, "/sessions 2")
    let identifier = TelegramControl.sessionIdentifier(project: "/tmp/project", path: "/tmp/session.jsonl")
    let sessionAction = "session:\(identifier)"
    XCTAssertEqual(try callback(command: sessionAction).authorizedCallback(userID: 42)?.command, sessionAction)
    XCTAssertLessThanOrEqual(sessionAction.utf8.count, 64)
    XCTAssertNil(try callback(command: "session:\(UUID().uuidString)").authorizedCallback(userID: 42))
    XCTAssertNil(try callback(command: "/last").authorizedCallback(userID: 42))
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

  func testSessionIdentifiersSurviveListRefreshAndAreScopedToProjectAndPath() {
    let project = "/tmp/project"
    let path = "/tmp/project/session.jsonl"
    let id = TelegramControl.sessionIdentifier(project: project, path: path)
    XCTAssertEqual(id, TelegramControl.sessionIdentifier(project: project, path: path))
    XCTAssertEqual(id.count, 32)
    XCTAssertNotEqual(id, TelegramControl.sessionIdentifier(project: "/tmp/other", path: path))
    XCTAssertNotEqual(id, TelegramControl.sessionIdentifier(project: project, path: "/tmp/other.jsonl"))
    let session = SessionItem(path: path, title: "旧会话", modifiedAt: .distantPast)
    // No in-memory button mapping is needed: the same saved session resolves
    // after building a new list or restarting the app.
    XCTAssertEqual(TelegramControl.sessionForIdentifier(id, project: project,
      sessions: [session])?.path, path)
    XCTAssertNil(TelegramControl.sessionForIdentifier(id, project: "/tmp/other", sessions: [session]))
  }

  func testSessionChoicesIncludeProjectHistoryAndCurrentDraftWithoutDuplicates() {
    let old = SessionItem(path: "/sessions/old.jsonl", title: "历史任务", modifiedAt: .distantPast)
    let recent = SessionItem(path: "/sessions/recent.jsonl", title: "最近任务", modifiedAt: .now)
    XCTAssertEqual(TelegramControl.sessionChoices([recent, old, recent],
      currentPath: old.path, currentTitle: "当前会话").map(\.path), [recent.path, old.path])
    let draft = TelegramControl.sessionChoices([recent, old],
      currentPath: "/sessions/draft.jsonl", currentTitle: "当前草稿")
    XCTAssertEqual(draft.map(\.path), ["/sessions/draft.jsonl", recent.path, old.path])
    XCTAssertEqual(draft.first?.title, "当前草稿")
    XCTAssertEqual(TelegramControl.sessionChoices([recent], currentPath: "",
      currentTitle: "新会话").map(\.path), [recent.path])
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

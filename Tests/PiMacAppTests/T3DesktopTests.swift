import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3DesktopTests {
  @Test func cachedShellIsVisibleBeforeConnectionButCannotAuthorizeCommands() throws {
    let suite = "pimac-cache-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(
      try JSONSerialization.data(withJSONObject: [
        "projects": [["id": "project-1", "workspaceRoot": "/tmp/project"]],
        "threads": [["id": "thread-1", "projectId": "project-1"]],
      ]), forKey: "t3DesktopShellCache")
    let client = T3DesktopClient(defaults: defaults)
    #expect(client.projects.count == 1)
    #expect(client.thread("thread-1") != nil)
    #expect(!client.isConnected)
  }

  @Test func unchangedShellIsDeliveredOnlyOnceIncludingDiskCache() throws {
    let suite = "pimac-poll-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let snapshot: [String: Any] = ["threads": [["id": "thread-1", "title": "Before"]]]
    defaults.set(
      try JSONSerialization.data(withJSONObject: snapshot), forKey: "t3DesktopShellCache")
    let client = T3DesktopClient(defaults: defaults)
    var deliveries = 0
    client.onShell = { _ in deliveries += 1 }
    client.applyShell(snapshot)
    client.applyShell(snapshot)
    #expect(deliveries == 1)
    client.applyShell(["threads": [["id": "thread-1", "title": "After"]]])
    #expect(deliveries == 2)
    #expect(client.thread("thread-1")?["title"] as? String == "After")
    client.stop()
    client.applyShell(client.shell)
    #expect(deliveries == 3)
  }

  @Test func snapshotIdentityIncludesContentBeyondThreadEventSequence() throws {
    let before: [String: Any] = [
      "snapshotSequence": 42,
      "projection": ["messages": [["id": "inherited-message", "text": "Before"]]],
    ]
    let reordered: [String: Any] = [
      "projection": ["messages": [["text": "Before", "id": "inherited-message"]]],
      "snapshotSequence": 42,
    ]
    let after: [String: Any] = [
      "snapshotSequence": 42,
      "projection": ["messages": [["id": "inherited-message", "text": "After"]]],
    ]
    let first = try T3DesktopClient.snapshotFingerprint(before)
    #expect(first == (try T3DesktopClient.snapshotFingerprint(reordered)))
    #expect(first != (try T3DesktopClient.snapshotFingerprint(after)))
  }

  @Test func snapshotAcknowledgementBelongsToEachSubscriptionAndRetriesIncompleteAssets() throws {
    let fingerprint = try T3DesktopClient.snapshotFingerprint(["snapshotSequence": 42])
    var deliveries = 0
    let first = T3DesktopClient.ThreadWatch(
      threadID: "thread", receive: { _ in deliveries += 1 }, receiveUI: { _ in })
    first.deliver([:], fingerprint: fingerprint, complete: true)
    #expect(first.deliveredSnapshot == fingerprint)
    let reopened = T3DesktopClient.ThreadWatch(
      threadID: "thread", receive: { _ in deliveries += 1 }, receiveUI: { _ in })
    #expect(reopened.deliveredSnapshot == nil)
    // 旧读取完成，不能把新观察者标成已更新。
    first.deliver([:], fingerprint: fingerprint, complete: true)
    #expect(reopened.deliveredSnapshot == nil)
    reopened.deliver([:], fingerprint: fingerprint, complete: false)
    #expect(reopened.deliveredSnapshot == nil)
    reopened.deliver([:], fingerprint: fingerprint, complete: true)
    #expect(reopened.deliveredSnapshot == fingerprint)
    reopened.invalidate()
    #expect(reopened.deliveredSnapshot == nil)
    #expect(first.deliveredSnapshot == fingerprint)
    #expect(deliveries == 4)
  }

  @Test func snapshotCallbackInvalidationIsNotOverwritten() throws {
    let fingerprint = try T3DesktopClient.snapshotFingerprint(["snapshotSequence": 42])
    var observer: T3DesktopClient.ThreadWatch!
    observer = T3DesktopClient.ThreadWatch(
      threadID: "thread", receive: { _ in observer.invalidate() }, receiveUI: { _ in })
    observer.deliver([:], fingerprint: fingerprint, complete: true)
    #expect(observer.deliveredSnapshot == nil)
  }

  @Test func connectionFailuresShowStageWithoutLeakingErrorDetails() {
    let error = NSError(
      domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
      userInfo: [NSLocalizedDescriptionKey: "secret-token private-prompt"])
    let status = T3DesktopClient.connectionFailureStatus(error, phase: "同步模型配置")
    #expect(status.contains("同步模型配置：请求超时"))
    #expect(!status.contains("secret-token"))
    #expect(!status.contains("private-prompt"))
    #expect(
      T3DesktopClient.connectionFailureStatus(
        T3DesktopClient.ClientError.unauthorized, phase: "读取会话状态"
      ).contains("授权已失效"))
  }

  @Test(.timeLimit(.minutes(1)))
  func desktopReconnectsAndRetainsRefreshRequestsDuringPolling() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = repository.appendingPathComponent("sidecars/t3-server/tests/fixtures/pi.mjs")
    let binary = root.appendingPathComponent("fixture-pi")
    try "#!/bin/sh\nexec node \"\(fixture.path)\" \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "pimac-reconnect-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(binary.path, forKey: "piPath")
    let workspace = WorkspaceModel(restoreUserState: false)
    // Transport fixtures stay loopback-only.
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let service = T3BridgeService(defaults: defaults)
    let client = T3DesktopClient(defaults: defaults)
    defer {
      client.stop()
      service.stop()
      workspace.disconnectAll()
    }
    let state = root.appendingPathComponent("state")
    try startT3ProtocolFixture(
      service: service, workspace: workspace, stateDirectory: state, binary: binary,
      model: "test/model")
    var requestedFollowUp = false
    var liveDeliveries = 0
    client.onShell = { [weak client] snapshot in
      guard let client, snapshot["refreshProbe"] == nil else { return }
      liveDeliveries += 1
      guard !requestedFollowUp else { return }
      requestedFollowUp = true
      // 模拟 Settle 在轮询途中请求刷新；探针只有后续真正读取 Server 才会被移除。
      client.requestRefresh()
      var probe = snapshot
      probe["refreshProbe"] = true
      client.applyShell(probe)
    }
    client.start(service: service)
    try await client.waitUntilReady()
    #expect(requestedFollowUp)
    #expect(liveDeliveries == 2)
    #expect(client.shell["refreshProbe"] == nil)
    client.onShell = nil
    #expect(!client.providers.isEmpty)
    let projectID = try await client.ensureProject(root)
    let threadID = UUID().uuidString
    try await client.dispatch(
      [
        "type": "thread.create", "threadId": threadID, "projectId": projectID,
        "title": "Settlement transport",
        "modelSelection": ["instanceId": "pi", "model": "test/model"],
        "runtimeMode": "full-access", "interactionMode": "default",
        "branch": NSNull(), "worktreePath": NSNull(),
      ], refreshAfter: false)
    try await client.refreshShell()
    #expect(client.thread(threadID) != nil)
    let firstOwner = UUID()
    let secondOwner = UUID()
    var firstDeliveries = 0
    var secondDeliveries = 0
    client.watch(threadID, owner: firstOwner) { _ in firstDeliveries += 1 }
    try await client.refresh()
    #expect(firstDeliveries == 1)
    try await client.refresh()
    #expect(firstDeliveries == 1)
    // 同一快照必须交付给新观察者，但不能重复刷新已有页面。
    client.watch(threadID, owner: secondOwner) { _ in secondDeliveries += 1 }
    try await client.refresh()
    #expect(firstDeliveries == 1)
    #expect(secondDeliveries == 1)
    client.unwatch(owner: firstOwner)
    client.unwatch(owner: secondOwner)
    try await client.dispatch(
      [
        "type": "thread.settle", "threadId": threadID,
      ], refreshAfter: false)
    try await client.refreshShell()
    #expect(WorkspaceModel.isSettled(try #require(client.thread(threadID))))
    try await client.dispatch(
      [
        "type": "thread.unsettle", "threadId": threadID, "reason": "user",
      ], refreshAfter: false)
    // 列表专用刷新也必须保留读取途中发出的后续请求，不能把旧快照当成写入确认。
    var shellFollowUp: Task<Void, Error>?
    client.onShell = { [weak client] snapshot in
      guard let client, shellFollowUp == nil else { return }
      shellFollowUp = Task { try await client.refreshShell() }
      var probe = snapshot
      probe["shellProbe"] = true
      client.applyShell(probe)
    }
    try await client.refreshShell()
    try await shellFollowUp?.value
    #expect(shellFollowUp != nil)
    #expect(client.shell["shellProbe"] == nil)
    #expect(!WorkspaceModel.isSettled(try #require(client.thread(threadID))))
    client.onShell = nil
    // This is the same shutdown barrier used by development hot reload.
    #expect(await service.stopAndWait())
    let marker = state.appendingPathComponent("child-owner.json")
    // 超时强制退出可保留诊断 PID 文件；真正的停止屏障是进程退出与内核租约释放。
    #expect(T3BridgeStateLease.isAvailable(state.appendingPathComponent("child-owner.lock")))
    #expect(!service.isStopping)
    for _ in 0..<100 where client.isConnected {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(!client.isConnected)
    // A leftover diagnostic file is no longer confused with a live OS lock.
    try Data("stale marker".utf8).write(to: marker)
    #expect(await service.stopAndWait())
    #expect(FileManager.default.fileExists(atPath: marker.path))
    // Malformed legacy ownership still needs explicit operator recovery.
    try FileManager.default.removeItem(at: marker)
    try startT3ProtocolFixture(
      service: service, workspace: workspace, stateDirectory: state, binary: binary,
      model: "test/model")
    try await client.waitUntilReady()
    #expect(!client.providers.isEmpty)
    #expect(client.status == "T3 Server 已连接")
  }

  @Test func reusableDateParsersSupportBothTimestampFormats() {
    let seconds = T3DesktopClient.date("2026-10-03T00:00:00Z")
    let fractional = T3DesktopClient.date("2026-10-03T00:00:00.125Z")
    #expect(seconds != .distantPast)
    #expect(abs(fractional.timeIntervalSince(seconds) - 0.125) < 0.001)
    #expect(T3DesktopClient.date("invalid") == .distantPast)
    #expect(T3DesktopClient.date(nil) == .distantPast)
  }

  @Test func sessionOrderDoesNotChangeWhenConcurrentThreadsUpdate() {
    let older: [String: Any] = [
      "id": "older", "projectId": "project", "title": "Older",
      "createdAt": "2026-10-01T00:00:00Z", "updatedAt": "2026-10-03T00:00:00Z",
    ]
    let newer: [String: Any] = [
      "id": "newer", "projectId": "project", "title": "Newer",
      "createdAt": "2026-10-02T00:00:00Z", "updatedAt": "2026-10-02T00:00:00Z",
    ]
    let initial = WorkspaceModel.sessionCatalog(threads: [older, newer], projectID: "project")
    #expect(initial.map(\.path) == ["t3:newer", "t3:older"])
    var updated = older
    updated["latestMessageAt"] = "2026-10-04T00:00:00Z"
    updated["title"] = "Updated title"
    let refreshed = WorkspaceModel.sessionCatalog(threads: [newer, updated], projectID: "project")
    #expect(refreshed.map(\.path) == initial.map(\.path))
    #expect(refreshed.last?.title == "Updated title")
    #expect(refreshed.last!.modifiedAt > initial.last!.modifiedAt)
  }

  @Test func sessionOrderUsesServerReactivationNotMessageActivity() {
    let older: [String: Any] = [
      "id": "older", "projectId": "project", "createdAt": "2026-10-01T00:00:00Z",
      "latestUserMessageAt": "2026-10-04T00:00:00Z",
      "latestRunRequestedAt": "2026-10-04T00:00:00Z",
    ]
    let newer: [String: Any] = [
      "id": "newer", "projectId": "project", "createdAt": "2026-10-02T00:00:00Z",
    ]
    #expect(
      WorkspaceModel.sessionCatalog(threads: [older, newer], projectID: "project")
        .map(\.path) == ["t3:newer", "t3:older"])
    var reopened = older
    reopened["unsettledAt"] = "2026-10-03T00:00:00Z"
    #expect(
      WorkspaceModel.sessionCatalog(threads: [newer, reopened], projectID: "project")
        .map(\.path) == ["t3:older", "t3:newer"])
  }

  @Test func sessionManualOrderFollowsKeylessThreadsAndUsesIDTies() {
    let threads: [[String: Any]] = [
      ["id": "b", "projectId": "project", "activeOrderKey": "n"],
      ["id": "a", "projectId": "project", "activeOrderKey": "n"],
      [
        "id": "first-key", "projectId": "project", "activeOrderKey": "b",
        "unsettledAt": "2026-10-05T00:00:00Z",
      ],
      ["id": "new", "projectId": "project", "createdAt": "2026-10-02T00:00:00Z"],
      ["id": "missing", "projectId": "project", "unsettledAt": NSNull()],
      ["id": "invalid", "projectId": "project", "createdAt": "invalid"],
    ]
    let expected = ["t3:new", "t3:invalid", "t3:missing", "t3:first-key", "t3:a", "t3:b"]
    #expect(
      WorkspaceModel.sessionCatalog(threads: threads, projectID: "project").map(\.path)
        == expected)
    #expect(
      WorkspaceModel.sessionCatalog(threads: threads.reversed(), projectID: "project")
        .map(\.path) == expected)
  }

  @Test func sessionCreationTiesHaveDeterministicOrder() {
    let threads: [[String: Any]] = [
      ["id": "b", "projectId": "project", "createdAt": "2026-10-02T00:00:00Z"],
      ["id": "a", "projectId": "project", "createdAt": "2026-10-02T00:00:00Z"],
      ["id": "other", "projectId": "other"],
    ]
    let expected = ["t3:a", "t3:b"]
    #expect(
      WorkspaceModel.sessionCatalog(threads: threads, projectID: "project").map(\.path) == expected)
    #expect(
      WorkspaceModel.sessionCatalog(threads: threads.reversed(), projectID: "project").map(\.path)
        == expected)
  }

  @Test func historicalPathsCannotBecomeRuntimeTargets() {
    #expect(AppModel.threadID(from: "/tmp/session.jsonl") == nil)
    #expect(AppModel.threadID(from: "t3:") == nil)
    #expect(AppModel.threadID(from: "t3:thread-1") == "thread-1")
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.connectionState = .connected
    #expect(!model.canSubmitPrompt)  // A UI flag cannot replace Server readiness.
    #expect(!model.supportsFastMode)
    #expect(!model.canManageAccounts)
  }

  @Test(.timeLimit(.minutes(2)))
  func desktopUsesNativeLoopbackServerWithoutPublicAdministration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = repository.appendingPathComponent("sidecars/t3-server/tests/fixtures/pi.mjs")
    let binary = root.appendingPathComponent("fixture-pi")
    try "#!/bin/sh\nexec node \"\(fixture.path)\" \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "pimac-desktop-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(binary.path, forKey: "piPath")
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = WorkspaceModel(restoreUserState: false)
    // Transport fixtures stay loopback-only.
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let service = T3BridgeService(
      defaults: defaults, stateDirectory: root.appendingPathComponent("state"))
    let client = T3DesktopClient(defaults: defaults)
    defer {
      client.stop()
      service.stop()
      workspace.disconnectAll()
    }
    let originalEnvironment = ProcessInfo.processInfo.environment
    try startT3ProtocolFixture(
      service: service, workspace: workspace,
      stateDirectory: root.appendingPathComponent("state"), binary: binary, model: "test/model")
    #expect(ProcessInfo.processInfo.environment == originalEnvironment)
    client.start(service: service)
    try await client.waitUntilReady()
    // 所有非 Pi 实例都已禁用；连 pending Codex 快照也不能触发原生探测。
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent("state/fixture-native-probes.log").path))
    let model = AppModel(startupProjectURL: root, continueLastSession: false)
    defer { model.disconnect() }
    model.attach(to: client)
    for _ in 0..<200 where !model.canSubmitPrompt {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.canSubmitPrompt)
    // 新聊天在首次发送前只保留本地状态，不应提前创建 Server 线程。
    #expect(model.currentSessionPath.isEmpty)
    model.changeModel(to: "test/model")
    for _ in 0..<200 where model.isBusy { try await Task.sleep(for: .milliseconds(50)) }
    #expect(model.thinkingLevels.contains("xhigh"))
    #expect(model.thinkingLevels.contains("max"))
    #expect(model.selectedModelId == "test/model")
    model.changeThinkingLevel(to: "xhigh")
    for _ in 0..<200 where model.isBusy {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.selectedThinkingLevel == "xhigh")
    #expect(!model.isBusy)
    model.composerText = "tools"
    model.sendPrompt()
    // 不让出 MainActor，断言网络请求开始前已显示且输入框已清空。
    let sent = try #require(model.messages.last)
    #expect(sent.kind == .user && sent.text == "tools")
    #expect(model.composerText.isEmpty)
    // 首次发送异步创建线程；先等待身份可用，再模拟未包含本地回显的旧快照。
    for _ in 0..<200 where model.threadID == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    let threadID = try #require(model.threadID)
    model.apply(["thread": ["id": threadID, "messages": []]])
    #expect(model.messages.last?.id == sent.id)  // 旧快照不能吞掉本地回显。
    for _ in 0..<200 where model.lastSettledTurnID == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.messages.filter { $0.kind == .user && $0.text == "tools" }.count == 1)
    #expect(model.messages.first { $0.kind == .user && $0.text == "tools" }?.id == sent.id)
    // 终态正文先于按需工具详情到达，等待完整输出而不是依赖旧的串行交付。
    for _ in 0..<200
    where !model.messages.contains(where: {
      $0.toolName == "codemode" && $0.text == "Script completed\nOutput:\n1"
    })
      || !model.messages.contains(where: {
        $0.toolInput == "fixture.txt" && $0.text == "done\nsecond line\nthird line"
      })
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    let read = try #require(
      model.messages.first { $0.toolName == "read" && $0.toolInput == "fixture.txt" })
    // Wire snapshots omit output; official detail hydration must restore it for cards.
    #expect(read.text == "done\nsecond line\nthird line")
    #expect(read.toolInput == "fixture.txt")
    #expect(!read.isRunning)
    let code = try #require(model.messages.first { $0.toolName == "codemode" })
    #expect(code.toolInput == "const value = 1;\ntext(value);")
    #expect(code.text == "Script completed\nOutput:\n1")
    // Stock Pi Adapter projects tools as flat items, including nested Pi events.
    #expect(code.childToolEntries.isEmpty)
    #expect(model.messages.contains { $0.toolInput == "nested.txt" })
    #expect(model.messages.contains { $0.kind == .assistant })
    #expect(model.lastSettledTurnID != nil)  // Also covers turns completed between polls.
    #expect(model.terminalStopReason == nil)
    model.refreshCodexAccounts()
    for _ in 0..<100 where model.stats == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.stats?.contextPercent == 2)
    #expect(model.stats?.totalTokens == 200)
    // Pi telemetry preserves the assistant message's reported USD cost.
    #expect(model.stats?.cost == 0.012)
    #expect(defaults.data(forKey: "t3DesktopShellCache") != nil)
    #expect(defaults.data(forKey: "t3DesktopV2Metrics.\(model.threadID!)") != nil)
    // The fixture emits its response immediately; zero measured duration must not invent speed.
    #expect(model.outputTokensPerSecond == nil)
    let beforeCompact = model.lastSettledTurnID
    model.compact()
    for _ in 0..<200 where model.lastSettledTurnID == beforeCompact || model.isBusy {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.lastSettledTurnID != beforeCompact)
    #expect(!model.isBusy)
    model.composerText = "slow"
    model.sendPrompt()
    for _ in 0..<100 where !model.isStreaming {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.isStreaming)
    model.composerText = "steer-now"
    model.sendPrompt(delivery: .steer)
    for _ in 0..<100 where !model.canSubmitPrompt {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.composerText.isEmpty)
    #expect(model.queuedPrompts.isEmpty)
    #expect(!model.awaitingAgentStart)
    #expect(model.isStreaming)
    model.composerText = "queued-followup"
    model.sendPrompt(delivery: .followUp)
    for _ in 0..<100 where model.queuedPrompts.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.queuedPrompts.count == 1)
    #expect(model.composerText.isEmpty)
    #expect(!model.canRestartSafely)
    for _ in 0..<200
    where !model.messages.contains(where: {
      $0.kind == .assistant && $0.text == "Reply: queued-followup"
    }) {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.queuedPrompts.isEmpty)
    #expect(
      model.messages.contains { $0.kind == .assistant && $0.text == "Reply: queued-followup" })
    let id = try #require(model.threadID)
    let searchSession = SessionItem(path: "t3:\(id)", title: "搜索测试", modifiedAt: .now)
    // 搜索必须走真实 Server 的数据库路径，并返回摘要，而不是逐会话下载详情。
    let nativeResults = try await client.searchSessions(
      query: "queued-followup", sessions: [searchSession])
    #expect(nativeResults.map(\.id) == [searchSession.path])
    #expect(nativeResults.first?.snippet?.contains("queued-followup") == true)
    let phraseResults = try await client.searchSessions(
      query: "Reply: queued-followup", sessions: [searchSession])
    #expect(phraseResults.map(\.id) == [searchSession.path])
    // 旧 title:/text: 语法不再解释；标题和工具输出也不补入原生正文结果。
    for query in ["text:queued-followup", "搜索测试", "fixture.txt"] {
      let results = try await client.searchSessions(query: query, sessions: [searchSession])
      #expect(results.isEmpty)
    }
    let noMatches = try await client.searchSessions(
      query: "definitely-no-match-53b027", sessions: [searchSession])
    #expect(noMatches.isEmpty)
    let detail = try await client.request("/api/orchestration/threads/\(id)")
    #expect(
      ((detail["projection"] as? [String: Any])?["thread"] as? [String: Any])?["id"] as? String
        == id)
    // 从真实桌面入口停止无限运行的任务，覆盖公开命令校验及队列暂停语义。
    model.composerText = "wait"
    model.sendPrompt()
    for _ in 0..<200 where !model.isStreaming {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.isStreaming)
    let runningDetail = try await client.request("/api/orchestration/threads/\(id)")
    let runs = (runningDetail["projection"] as? [String: Any])?["runs"] as? [[String: Any]]
    let stoppedRun = try #require(
      runs?.last { T3V2Presentation.active.contains($0["status"] as? String ?? "") }?["id"]
        as? String)
    // 执行中状态可能先于 dispatch 回执投影，不能在上一次提交仍锁定时发送后续消息。
    for _ in 0..<200 where !model.canSubmitPrompt {
      try await Task.sleep(for: .milliseconds(50))
    }
    try #require(model.canSubmitPrompt)
    model.composerText = "must-remain-queued"
    model.sendPrompt(delivery: .followUp)
    for _ in 0..<200 where model.queuedPrompts.isEmpty {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.queuedPrompts.count == 1)
    model.abort()
    for _ in 0..<200 where model.isStreaming || !model.queueHeld {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(!model.isStreaming)
    #expect(model.lastSettledTurnID == stoppedRun)
    #expect(model.terminalStopReason == "aborted")
    #expect(model.queueHeld)
    #expect(model.queuedPrompts.count == 1)
    #expect(!model.messages.contains { $0.text == "Reply: must-remain-queued" })
    // 附件读取失败也保留可编辑的原消息，并明确标记未确认，不丢失新草稿。
    model.composerText = "missing-image"
    model.attachments = [
      PromptAttachment(
        url: root.appendingPathComponent("missing.png"), mimeType: "image/png")
    ]
    model.sendPrompt()
    let failedID = try #require(model.messages.last?.id)
    #expect(model.messages.last?.text == "missing-image")
    #expect(model.messages.last?.attachments.count == 1)
    model.composerText = "new draft"
    for _ in 0..<100 where !model.canSubmitPrompt {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.messages.first { $0.id == failedID }?.isError == true)
    #expect(model.composerText == "new draft")
    #expect(model.statusText.contains("提交未确认"))
    // Optional LAN transport never changes the desktop's loopback Server.
    #expect(service.serverURL?.host == "127.0.0.1")
    let shell = try await client.request("/api/orchestration/shell")
    #expect((shell["threads"] as? [[String: Any]])?.contains { $0["id"] as? String == id } == true)
  }
}

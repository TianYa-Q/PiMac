import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct MessageRecoveryTests {
  private let selection: [String: Any] = [
    "instanceId": "pi", "model": "test/model", "options": [["id": "thinking", "value": "medium"]],
  ]

  private func directory() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/delivery-recovery/tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func save(
    _ store: MessageOutboxStore, root: URL, creates: Bool = true,
    attachments: [PromptAttachment] = []
  ) throws -> OutboxMessage {
    try store.save(
      prompt: #require(AppModel.makePrompt("保留原稿", attachments: attachments, delivery: .steer)),
      messageID: UUID().uuidString, threadID: UUID().uuidString, project: root,
      selection: selection, createsThread: creates, context: "用户：之前的问题\n助手：已完成的分析")
  }

  private final class Transport: MessageDeliveryTransport {
    var environment = "environment"
    var project = "project"
    var exists = false
    var received: Set<String> = []
    var hideMessages = false
    var dropCreate = false
    var dropDispatch = false
    var commands: [(String, Data)] = []
    var receipts: Set<String> = []
    var runs = 0
    var onDispatch: (() throws -> Void)?
    var pauseMessage = false
    var pendingMessage: CheckedContinuation<Void, Never>?
    var inspectionError: Error?
    var inspectionFailures = 0
    var inspections = 0
    var snapshotFailures = 0
    var snapshots = 0
    var projectError: Error?
    var onProject: (() throws -> Void)?
    var pausePreflight = false
    var pendingPreflight: CheckedContinuation<Void, Never>?
    var uploadError: Error?
    var uploads = 0
    var uploadedImages = 0

    func recoveryEnvironmentID() async throws -> String {
      inspections += 1
      if pausePreflight { await withCheckedContinuation { pendingPreflight = $0 } }
      if inspectionFailures > 0 {
        inspectionFailures -= 1
        throw inspectionError ?? URLError(.timedOut)
      }
      return environment
    }
    func recoveryProjectID(_ url: URL) async throws -> String? {
      try onProject?()
      if let projectError { throw projectError }
      return project
    }
    func ensureProject(_ url: URL) async throws -> String { project }
    func recoverySnapshot(threadID: String) async throws -> [String: Any] {
      snapshots += 1
      if snapshotFailures > 0 {
        snapshotFailures -= 1
        throw URLError(.timedOut)
      }
      guard exists else { throw T3DesktopClient.HTTPFailure(status: 404) }
      return [
        "projection": [
          "thread": ["id": threadID, "projectId": project],
          "messages": hideMessages ? [] : received.map { ["id": $0] },
        ]
      ]
    }
    func persistAttachments(_ images: [[String: Any]], threadID: String, messageID: String)
      async throws -> [[String: Any]]
    {
      uploads += 1
      uploadedImages += images.count
      if let uploadError { throw uploadError }
      return []
    }
    func dispatch(_ fields: [String: Any], commandID: String, refreshAfter: Bool) async throws
      -> [String: Any]
    {
      commands.append(
        (commandID, try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])))
      if receipts.insert(commandID).inserted {
        if fields["type"] as? String == "thread.create" { exists = true }
        if let id = fields["messageId"] as? String {
          received.insert(id)
          runs += 1
        }
      }
      try onDispatch?()
      if fields["type"] as? String == "message.dispatch", pauseMessage {
        pauseMessage = false
        await withCheckedContinuation { pendingMessage = $0 }
      }
      if fields["type"] as? String == "thread.create", dropCreate {
        dropCreate = false
        throw URLError(.networkConnectionLost)
      }
      if fields["type"] as? String == "message.dispatch", dropDispatch {
        dropDispatch = false
        throw URLError(.networkConnectionLost)
      }
      return [:]
    }
  }

  @Test func activeSubmissionAutomaticallyRecoversPreflightAndLostRepliesWithFrozenIdentity()
    async throws
  {
    let root = try directory()
    let store = MessageOutboxStore()
    let transport = Transport()
    transport.inspectionFailures = 1
    transport.dropCreate = true
    transport.dropDispatch = true
    transport.hideMessages = true
    let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
    let record = try save(store, root: root)
    #expect(await coordinator.deliver(record.id, retryDelays: [.zero, .zero, .zero]))
    #expect(transport.inspections == 4)
    #expect(transport.commands.count == 4)
    #expect(transport.commands[0] == transport.commands[1])
    #expect(transport.commands[2] == transport.commands[3])
    #expect(transport.runs == 1)
    #expect(coordinator.activeThreads.isEmpty)
  }

  @Test func automaticRecoveryIsBoundedAndDoesNotRetryPermanentFailures() async throws {
    let root = try directory()
    for error: Error in [
      URLError(.timedOut), T3DesktopClient.ClientError.unauthorized,
      MessageRecoveryCoordinator.RecoveryError.environmentChanged,
      T3DesktopClient.HTTPFailure(status: 403),
    ] {
      let store = MessageOutboxStore()
      let transport = Transport()
      transport.inspectionFailures = 10
      transport.inspectionError = error
      let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
      let record = try save(store, root: root)
      #expect(await coordinator.deliver(record.id, retryDelays: [.zero, .zero]) == false)
      #expect(transport.inspections == (error is URLError ? 3 : 1))
      #expect(transport.commands.isEmpty)
      #expect(store.message(record.id)?.state == .unknown)
      #expect(coordinator.activeThreads.isEmpty)
    }
  }

  @Test func explicitRejectionNeverAutomaticallyReplays() async throws {
    let root = try directory()
    let store = MessageOutboxStore()
    let transport = Transport()
    let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
    transport.onDispatch = {
      throw T3DesktopClient.RPCFailure(exit: ["_tag": "ModelUnavailableError"])
    }
    let rejected = try save(store, root: root)
    #expect(await coordinator.deliver(rejected.id, retryDelays: [.zero]) == false)
    #expect(store.message(rejected.id)?.state == .rejected)
    #expect(transport.commands.count == 1)

  }

  @Test func attachmentRetriesReadOnlyPreflightButNotAmbiguousUpload() async throws {
    let root = try directory()
    let source = root.appendingPathComponent("attachment.png")
    try #require(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )
    ).write(to: source)
    for uploadFails in [false, true] {
      let store = MessageOutboxStore(directory: root.appendingPathComponent(UUID().uuidString))
      let transport = Transport()
      transport.exists = true
      transport.snapshotFailures = 1
      if uploadFails { transport.uploadError = URLError(.timedOut) }
      let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
      let record = try save(
        store, root: root, creates: false,
        attachments: [PromptAttachment(url: source, mimeType: "image/png")])
      #expect(await coordinator.deliver(record.id, retryDelays: [.zero, .zero]) == !uploadFails)
      #expect(transport.snapshots == 2)
      #expect(transport.uploads == 1)
      #expect(transport.uploadedImages == 1)
      #expect(transport.commands.count == (uploadFails ? 0 : 1))
      #expect(transport.runs == (uploadFails ? 0 : 1))
      let saved = try #require(store.message(record.id))
      #expect(saved.lastFailure?.stage == (uploadFails ? .upload : .snapshot))
      #expect(saved.lastFailure?.elapsedMilliseconds ?? -1 >= 0)
      #expect(saved.state == (uploadFails ? .unknown : .accepted))
      #expect(saved.dispatchCommandID == record.dispatchCommandID)
      try store.validateAttachments(saved)
      let reloaded = MessageOutboxStore(directory: store.storageDirectory)
      #expect(reloaded.message(record.id)?.lastFailure == saved.lastFailure)
      if uploadFails { #expect(saved.dispatchCommand == nil) }
    }
  }

  @Test func normalPreflightIsInFlightAndInterruptedPreparationRemainsRecoverable() async throws {
    let root = try directory()
    let store = MessageOutboxStore(directory: root.appendingPathComponent("outbox"))
    let record = try save(store, root: root, creates: false)
    let transport = Transport()
    transport.exists = true
    transport.pausePreflight = true
    let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
    let task = Task { await coordinator.deliver(record.id) }
    for _ in 0..<1000 where transport.pendingPreflight == nil { await Task.yield() }
    let continuation = try #require(transport.pendingPreflight)
    #expect(coordinator.activeThreads.contains(record.threadID))
    #expect(store.message(record.id)?.state == .sending)
    #expect(store.message(record.id)?.state.needsRecovery == false)
    #expect(store.message(record.id)?.entry.title == "你 · 正在提交")
    #expect(transport.commands.isEmpty)
    let restarted = MessageOutboxStore(directory: store.storageDirectory)
    #expect(restarted.message(record.id)?.state == .unknown)
    continuation.resume()
    #expect(await task.value)
  }

  @Test func missingThreadCanReturnOnlyAfterEnvironmentAndProjectAreRevalidated() async throws {
    let root = try directory()
    let store = MessageOutboxStore()
    let transport = Transport()
    let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
    let record = try save(store, root: root, creates: false)
    #expect(await coordinator.check(record.id) == .missing)
    transport.exists = true
    transport.environment = "other-environment"
    #expect(await coordinator.check(record.id) == .blocked)
    #expect(store.message(record.id)?.state == .missing)
    transport.environment = "environment"
    transport.projectError = T3DesktopClient.HTTPFailure(status: 404)
    #expect(await coordinator.check(record.id) == .blocked)
    #expect(store.message(record.id)?.lastFailure?.stage == .project)
    transport.projectError = nil
    #expect(await coordinator.check(record.id) == .ready)
    #expect(store.message(record.id)?.state == .unknown)
    #expect(transport.commands.isEmpty)
    #expect(await coordinator.deliver(record.id))
    #expect(transport.runs == 1)
    #expect(transport.commands.first?.0 == record.dispatchCommandID)
    #expect(
      !transport.commands.contains {
        String(data: $0.1, encoding: .utf8)?.contains("thread.create") == true
      })
  }

  @Test func authoritativeAcknowledgementDuringProjectReadConvergesWithoutDispatch() async throws {
    let root = try directory()
    for projectFails in [false, true] {
      let store = MessageOutboxStore()
      let transport = Transport()
      transport.exists = true
      let record = try save(store, root: root, creates: false)
      transport.onProject = {
        try store.acknowledge(threadID: record.threadID, messageIDs: [record.id])
      }
      if projectFails { transport.projectError = URLError(.timedOut) }
      let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
      #expect(await coordinator.deliver(record.id, retryDelays: [.zero]))
      #expect(store.message(record.id)?.state == .delivered)
      #expect(await coordinator.deliver(record.id))
      #expect(transport.commands.isEmpty)
      #expect(transport.uploads == 0)
    }
  }

  @Test func projectLookup404IsNotThreadMissingAndDiagnosticsRedactSecrets() async throws {
    let root = try directory()
    let store = MessageOutboxStore()
    let transport = Transport()
    transport.exists = true
    transport.projectError = T3DesktopClient.HTTPFailure(status: 404)
    let record = try save(store, root: root, creates: false)
    let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
    #expect(await coordinator.deliver(record.id) == false)
    #expect(store.message(record.id)?.state == .unknown)
    #expect(store.message(record.id)?.lastFailure?.stage == .project)
    transport.projectError = NSError(
      domain: NSURLErrorDomain, code: -1001,
      userInfo: [
        NSLocalizedDescriptionKey: "secret-value",
        NSURLErrorFailingURLStringErrorKey: "https://secret-value",
      ])
    #expect(await coordinator.check(record.id) == .blocked)
    let diagnostic = try #require(store.message(record.id)?.lastFailure)
    #expect(
      !String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self).contains(
        "secret-value"))
    #expect(transport.commands.isEmpty)
  }

  @Test func runningAgentAllowsCheckedRecoveryButNotConcurrentDeliveryOrCompaction() async throws {
    let root = try directory()
    let suite = "recovery-running-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let client = T3DesktopClient(defaults: defaults)
    let model = AppModel(restoreLastProjectOnLaunch: false)
    defer {
      model.disconnect()
      client.stop()
      defaults.removePersistentDomain(forName: suite)
    }
    let store = MessageOutboxStore()
    let transport = Transport()
    transport.exists = true
    let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
    let record = try save(store, root: root, creates: false)
    try store.update(record.id) { $0.state = .unknown }
    model.attach(to: client, deliveries: coordinator)
    model.projectURL = root
    model.currentSessionPath = "t3:\(record.threadID)"
    model.connectionState = .connected
    model.isStreaming = true
    #expect(model.isBusy)
    #expect(model.canCheckDeliveryRecovery)
    #expect(!model.canContinueDeliveryRecovery)
    model.checkDeliveryRecovery()
    #expect(!model.canCheckDeliveryRecovery)
    for _ in 0..<1000 where model.isCheckingDelivery { await Task.yield() }
    #expect(model.recoveryReady)
    #expect(model.canContinueDeliveryRecovery)
    model.isCompacting = true
    #expect(!model.canContinueDeliveryRecovery)
    model.isCompacting = false
    transport.pausePreflight = true
    model.continueDeliveryRecovery()
    #expect(!model.canCheckDeliveryRecovery)
    for _ in 0..<1000 where transport.pendingPreflight == nil { await Task.yield() }
    let continuation = try #require(transport.pendingPreflight)
    #expect(await coordinator.deliver(record.id) == false)
    continuation.resume()
    for _ in 0..<1000 where store.message(record.id)?.state != .accepted { await Task.yield() }
    #expect(store.message(record.id)?.state == .accepted)
    #expect(transport.runs == 1)
    let command = try #require(transport.commands.last)
    let fields = try #require(JSONSerialization.jsonObject(with: command.1) as? [String: Any])
    #expect(fields["dispatchMode"] as? [String: String] == ["type": "queue_after_active"])
  }

  @Test func cancellationDuringAutomaticBackoffPreservesInputAndReleasesThread() async throws {
    let root = try directory()
    let store = MessageOutboxStore()
    let transport = Transport()
    transport.inspectionFailures = 1
    let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
    let record = try save(store, root: root)
    let task = Task { await coordinator.deliver(record.id, retryDelays: [.seconds(60)]) }
    for _ in 0..<100 where store.message(record.id)?.state != .sending { await Task.yield() }
    #expect(store.message(record.id)?.state == .sending)
    #expect(await coordinator.deliver(record.id) == false)
    #expect(await coordinator.check(record.id) == .blocked)
    task.cancel()
    #expect(await task.value == false)
    #expect(store.message(record.id)?.state == .unknown)
    #expect(coordinator.activeThreads.isEmpty)
    #expect(transport.commands.isEmpty)
  }

  @Test func acknowledgementDuringBackoffWinsOverCancellation() async throws {
    let root = try directory()
    let store = MessageOutboxStore()
    let transport = Transport()
    transport.inspectionFailures = 1
    let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
    let record = try save(store, root: root)
    let task = Task { await coordinator.deliver(record.id, retryDelays: [.seconds(60)]) }
    for _ in 0..<1000 where store.message(record.id)?.lastFailure == nil { await Task.yield() }
    #expect(store.message(record.id)?.state == .sending)
    #expect(store.message(record.id)?.lastFailure?.stage == .environment)
    try store.acknowledge(threadID: record.threadID, messageIDs: [record.id])
    task.cancel()
    #expect(await task.value)
    #expect(store.message(record.id)?.state == .delivered)
    #expect(coordinator.activeThreads.isEmpty)
    #expect(transport.commands.isEmpty)
  }

  @Test func attachmentCopiesAndInFlightIdentitySurviveReloadAndCorruptionIsExplicit() throws {
    let root = try directory()
    let source = root.appendingPathComponent("资料.txt")
    try Data("附件内容".utf8).write(to: source)
    let location = root.appendingPathComponent("outbox")
    let store = MessageOutboxStore(directory: location)
    let record = try save(
      store, root: root, attachments: [PromptAttachment(url: source, mimeType: "text/plain")])
    let copy = try #require(record.attachments.first?.attachment.url)
    #expect(copy != source)
    #expect(record.rpcText.contains(copy.path))
    try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("original.saved"))
    try store.validateAttachments(record)
    try store.update(record.id) { $0.state = .sending }
    let reloaded = MessageOutboxStore(directory: location)
    let restored = try #require(reloaded.message(record.id))
    #expect(restored.state == .unknown)
    #expect(restored.dispatchCommandID == record.dispatchCommandID)
    #expect(restored.selection == record.selection)
    try Data("损坏内容".utf8).write(to: copy)
    #expect(throws: CocoaError.self) { try reloaded.validateAttachments(restored) }
    let archive = location.appendingPathComponent("outbox.json")
    try Data("broken archive".utf8).write(to: archive)
    let corrupt = MessageOutboxStore(directory: location)
    #expect(corrupt.failure != nil)
    #expect(throws: CocoaError.self) { _ = try save(corrupt, root: root) }
    #expect(try String(contentsOf: archive, encoding: .utf8) == "broken archive")
  }

  @Test func lostRepliesUseOriginalFrozenCommandsAcrossClientRestart() async throws {
    let root = try directory()
    let location = root.appendingPathComponent("outbox")
    let transport = Transport()
    transport.dropCreate = true
    let store = MessageOutboxStore(directory: location)
    let record = try save(store, root: root)
    let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
    #expect(await coordinator.deliver(record.id) == false)
    #expect(store.message(record.id)?.state == .unknown)
    let nextStore = MessageOutboxStore(directory: location)
    let next = MessageRecoveryCoordinator(store: nextStore, transport: transport)
    transport.dropDispatch = true
    #expect(await next.deliver(record.id) == false)
    #expect(transport.commands[0] == transport.commands[1])
    transport.hideMessages = true
    let lastStore = MessageOutboxStore(directory: location)
    let last = MessageRecoveryCoordinator(store: lastStore, transport: transport)
    #expect(await last.check(record.id) == .ready)
    #expect(transport.commands.count == 3, "检查不能执行变更")
    #expect(await last.deliver(record.id))
    #expect(transport.commands[2] == transport.commands[3])
    #expect(transport.runs == 1)
    #expect(lastStore.message(record.id)?.state == .accepted)
  }

  @Test func acceptedSnapshotHandsOffWithoutReplayingAndCannotRegressAfterLateFailure() async throws
  {
    let root = try directory()
    let store = MessageOutboxStore()
    let transport = Transport()
    let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
    let record = try save(store, root: root)
    transport.onDispatch = {
      if transport.received.contains(record.id) {
        try store.acknowledge(threadID: record.threadID, messageIDs: [record.id])
      }
    }
    transport.dropDispatch = true
    #expect(await coordinator.deliver(record.id))
    #expect(store.message(record.id)?.state == .delivered)
    #expect(await coordinator.deliver(record.id))
    #expect(transport.runs == 1)

    let second = try save(store, root: root, creates: false)
    try store.update(second.id) { $0.state = .unknown }
    transport.received.insert(second.id)
    let count = transport.commands.count
    #expect(await coordinator.check(second.id) == .accepted)
    #expect(transport.commands.count == count)
    transport.environment = "another-environment"
    #expect(await coordinator.check(second.id) == .blocked)
    #expect(store.message(second.id)?.state == .accepted)
    #expect(transport.commands.count == count)
  }

  @Test func missingThreadMigratesOnceAndPreservesContextAndEnvironmentBoundary() async throws {
    let root = try directory()
    let location = root.appendingPathComponent("outbox")
    let store = MessageOutboxStore(directory: location)
    let transport = Transport()
    let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
    let record = try save(store, root: root, creates: false)
    #expect(await coordinator.check(record.id) == .missing)
    #expect(transport.commands.isEmpty)
    let originals = try [#require(store.message(record.id))]
    let migrated = try store.migrate(originals)
    #expect(migrated.threadID != record.threadID)
    #expect(migrated.rpcText.contains("之前的问题"))
    #expect(migrated.rpcText.contains("不要逐条重新执行"))
    #expect(try store.migrate(originals).id == migrated.id)
    let reloaded = MessageOutboxStore(directory: location)
    #expect(reloaded.message(record.id)?.migratedTo == migrated.id)
    transport.environment = "another-environment"
    let next = MessageRecoveryCoordinator(store: reloaded, transport: transport)
    #expect(await next.check(migrated.id) == .blocked)
    #expect(await next.deliver(migrated.id) == false)
    #expect(transport.commands.isEmpty)
    transport.environment = "environment"
    #expect(await next.deliver(migrated.id))
    #expect(transport.runs == 1)
  }

  @Test func takeBackDraftIsDurableAndReplacedOnlyByAtomicNewSubmission() throws {
    let root = try directory()
    let store = MessageOutboxStore(directory: root.appendingPathComponent("outbox"))
    let record = try save(store, root: root, creates: false)
    try store.update(record.id) { $0.state = .draft }
    let reload = MessageOutboxStore(directory: root.appendingPathComponent("outbox"))
    #expect(reload.message(record.id)?.state == .draft)
    let edited = try #require(AppModel.makePrompt("修改后的原稿", attachments: [], delivery: .steer))
    let next = try reload.save(
      prompt: edited, messageID: UUID().uuidString, threadID: record.threadID, project: root,
      selection: selection, createsThread: false, context: record.context,
      replacingDraftID: record.id)
    #expect(reload.message(record.id)?.state == .dismissed)
    #expect(reload.message(next.id)?.text == "修改后的原稿")
  }

  @Test func failedPersistencePreservesComposerAndClosedTabsRemainDiscoverable() throws {
    let root = try directory()
    let invalid = root.appendingPathComponent("not-a-directory")
    try Data("blocked".utf8).write(to: invalid)
    let blocked = WorkspaceModel(restoreUserState: false, outboxDirectory: invalid)
    defer { blocked.disconnectAll() }
    blocked.server.didCompletePoll()
    let model = try #require(blocked.selectedModel)
    model.projectURL = root
    model.connectionState = .connected
    model.composerText = "保存失败时不能清空"
    model.sendPrompt()
    #expect(model.composerText == "保存失败时不能清空")
    #expect(blocked.deliveries.store.messages.isEmpty)

    let location = root.appendingPathComponent("working-outbox")
    let store = MessageOutboxStore(directory: location)
    let record = try save(store, root: root, creates: false)
    let suite = "recovery-discovery-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = WorkspaceModel(
      restoreUserState: false, server: T3DesktopClient(defaults: defaults),
      outboxDirectory: location)
    defer { workspace.disconnectAll() }
    let path = "t3:\(record.threadID)"
    #expect(workspace.filteredSessions.map(\.path) == [path])
    #expect(workspace.project(forSessionPath: path)?.url.path == root.path)
    workspace.openSession(path: path, in: root)
    #expect(workspace.selectedModel?.currentSessionPath == path)
    #expect(workspace.selectedModel?.recoveryRecords.first?.id == record.id)
    #expect(workspace.selectedModel?.messages.first?.text == record.rpcText)
  }

  @Test func concurrentRecoveryIsSerializedAndLateSourceAcceptanceSurfacesConflict() async throws {
    let root = try directory()
    let store = MessageOutboxStore()
    let transport = Transport()
    let coordinator = MessageRecoveryCoordinator(store: store, transport: transport)
    let record = try save(store, root: root)
    transport.pauseMessage = true
    let delivery = Task { await coordinator.deliver(record.id) }
    for _ in 0..<100 where transport.pendingMessage == nil { await Task.yield() }
    let gate = try #require(transport.pendingMessage)
    #expect(await coordinator.deliver(record.id) == false)
    #expect(await coordinator.check(record.id) == .blocked)
    gate.resume()
    #expect(await delivery.value)
    #expect(transport.runs == 1)

    let source = try save(store, root: root, creates: false)
    try store.update(source.id) { $0.state = .missing }
    let target = try store.migrate([#require(store.message(source.id))])
    try store.acknowledge(threadID: source.threadID, messageIDs: [source.id])
    #expect(store.message(target.id)?.state == .conflict)
    #expect(await coordinator.check(target.id) == .blocked)
    #expect(await coordinator.deliver(target.id) == false)
    try store.acknowledge(threadID: target.threadID, messageIDs: [target.id])
    #expect(store.message(target.id)?.state == .conflict)
    #expect(transport.runs == 1)
  }

  @Test func transientSaveFailureCanRetryWithoutRestartAndCorruptArchiveCanReload() throws {
    let root = try directory()
    let blocker = root.appendingPathComponent("blocker")
    try Data("blocked".utf8).write(to: blocker)
    let store = MessageOutboxStore(directory: blocker)
    #expect(throws: (any Error).self) { _ = try save(store, root: root) }
    #expect(store.failure != nil)
    try FileManager.default.moveItem(at: blocker, to: root.appendingPathComponent("blocker.saved"))
    try store.retryPersistence()
    #expect(store.failure == nil)
    _ = try save(store, root: root)

    let archive = blocker.appendingPathComponent("outbox.json")
    let original = try Data(contentsOf: archive)
    try Data("corrupt".utf8).write(to: archive)
    let reloaded = MessageOutboxStore(directory: blocker)
    #expect(reloaded.isReadOnly)
    try original.write(to: archive, options: .atomic)
    reloaded.reload()
    #expect(!reloaded.isReadOnly)
    #expect(reloaded.failure == nil)
    #expect(reloaded.messages.count == 1)
  }

  @Test func structuredErrorsRetainTypeButNeverExposeRawSecretText() {
    let failure = T3DesktopClient.RPCFailure(exit: [
      "_tag": "Failure",
      "cause": [
        "_tag": "Fail",
        "error": [
          "_tag": "OrchestrationV2DispatchCommandError", "message": "secret-value",
          "cause": ["name": "ProjectionStoreThreadNotFoundError", "message": "secret-value"],
        ],
      ],
    ])
    #expect(failure.threadMissing)
    #expect(failure.localizedDescription.contains("找不到原会话"))
    #expect(!failure.localizedDescription.contains("secret-value"))
  }
}

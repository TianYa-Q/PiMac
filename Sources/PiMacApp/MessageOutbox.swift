import Combine
import CryptoKit
import Foundation

struct OutboxAttachment: Codable, Equatable, Sendable {
  let attachment: PromptAttachment
  let digest: String
}

struct OutboxMessage: Identifiable, Codable, Equatable, Sendable {
  enum State: String, Codable, Sendable {
    case saved, sending, unknown, rejected, missing, draft, conflict, accepted, delivered, migrated,
      dismissed

    var isConfirmed: Bool { self == .accepted || self == .delivered }

    var needsRecovery: Bool {
      [.saved, .unknown, .rejected, .missing, .draft, .conflict].contains(self)
    }
  }

  let id: String
  let threadID: String
  let projectPath: String
  let text: String
  let rpcText: String
  let delivery: QueuedPromptDelivery
  let attachments: [OutboxAttachment]
  let selection: Data
  let context: String
  let createdAt: Date
  let createsThread: Bool
  let createCommandID: String
  let dispatchCommandID: String
  var environmentID: String?
  var createCommand: Data?
  var dispatchCommand: Data?
  var threadCreated = false
  var state: State = .saved
  var issue = "输入已保存在本机"
  var migratedTo: String?
  // 可选字段兼容已落盘的旧记录；只存受控阶段和安全错误，不保存 URL、凭据或响应正文。
  var lastFailure: MessageRecoveryCoordinator.FailureDiagnostic?

  var isVisible: Bool { ![.delivered, .migrated, .dismissed].contains(state) }
  var entry: ChatEntry {
    ChatEntry(
      id: id, kind: .user,
      title: state == .accepted
        ? "你" : state == .saved ? "你 · 已保存" : "你 · \(state.needsRecovery ? "待恢复" : "正在提交")",
      text: rpcText, isError: state.needsRecovery && state != .saved,
      attachments: attachments.map(\.attachment).filter(\.isImage), timestamp: createdAt)
  }
}

/// 未交接输入只有这一份事实来源，标签页关闭不负责清理它。
@MainActor
final class MessageOutboxStore: ObservableObject {
  private struct Archive: Codable {
    var version = 1
    var messages: [OutboxMessage]
  }

  @Published private(set) var messages: [OutboxMessage] = []
  @Published private(set) var failure: String?
  private let directory: URL?
  private var loadFailed = false
  var storageDirectory: URL? { directory }
  var isReadOnly: Bool { loadFailed }

  init(directory: URL? = nil) {
    self.directory = directory
    reload()
  }

  func reload() {
    guard let directory else { return }
    loadFailed = false
    failure = nil
    let file = directory.appendingPathComponent("outbox.json")
    do {
      let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
      guard archive.version == 1,
        Set(archive.messages.map(\.id)).count == archive.messages.count,
        archive.messages.allSatisfy({
          !$0.id.isEmpty && !$0.threadID.isEmpty && !$0.projectPath.isEmpty
        })
      else { throw CocoaError(.coderReadCorrupt) }
      // 崩溃可能发生在网络写入前后，不能把 sending 当成尚未发送。
      messages = archive.messages.map {
        var message = $0
        if message.state == .sending {
          message.state = .unknown
          message.issue = "上次提交中断，需要核对 Server 是否收到"
        }
        return message
      }
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return
    } catch {
      loadFailed = true
      failure = "发件箱读取失败；原记录已保留，禁止覆盖。请导出原记录后处理。"
    }
  }

  func retryPersistence() throws {
    guard !loadFailed else {
      reload()
      return
    }
    try commit(
      messages.map {
        var record = $0
        if record.state == .sending { record.state = .unknown }
        return record
      })
  }

  func records(threadID: String, project: URL) -> [OutboxMessage] {
    messages.filter {
      $0.threadID == threadID && $0.projectPath == project.standardizedFileURL.path && $0.isVisible
    }
  }

  func message(_ id: String) -> OutboxMessage? { messages.first { $0.id == id } }

  func update(_ id: String, _ change: (inout OutboxMessage) -> Void) throws {
    guard let index = messages.firstIndex(where: { $0.id == id }) else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    var next = messages
    change(&next[index])
    try commit(next)
  }

  /// 附件先导入私有持久目录，清单原子落盘后才允许清空 composer/发起网络请求。
  func save(
    prompt: QueuedPrompt, messageID: String, threadID: String, project: URL,
    selection: [String: Any], createsThread: Bool, context: String,
    replacingDraftID: String? = nil
  ) throws -> OutboxMessage {
    guard !loadFailed else { throw CocoaError(.coderReadCorrupt) }
    if let existing = message(messageID) {
      // 远端客户端可能重试同一 messageID；不允许换正文或跨项目冒充同一次提交。
      guard existing.threadID == threadID, existing.text == prompt.text,
        existing.projectPath == project.standardizedFileURL.path,
        existing.attachments.map(\.attachment.id) == prompt.attachments.map(\.id)
      else { throw CocoaError(.validationMultipleErrors) }
      return existing
    }
    do {
      var imported: [OutboxAttachment] = []
      for attachment in prompt.attachments {
        let data = try Data(contentsOf: attachment.url, options: .mappedIfSafe)
        let digest = Self.digest(data)
        var url = attachment.url
        if let directory {
          let folder = directory.appendingPathComponent("attachments/\(UUID().uuidString)")
          try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
          url = folder.appendingPathComponent(attachment.url.lastPathComponent)
          try data.write(to: url, options: .atomic)
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        imported.append(
          OutboxAttachment(
            attachment: PromptAttachment(
              id: attachment.id, url: url, mimeType: attachment.mimeType,
              replyImagePath: attachment.replyImagePath), digest: digest))
      }
      let record = OutboxMessage(
        id: messageID, threadID: threadID, projectPath: project.standardizedFileURL.path,
        text: prompt.text,
        rpcText: AppModel.rpcText(for: prompt.text, attachments: imported.map(\.attachment)),
        delivery: prompt.delivery, attachments: imported,
        selection: try JSONSerialization.data(withJSONObject: selection, options: [.sortedKeys]),
        context: context, createdAt: .now, createsThread: createsThread,
        createCommandID: UUID().uuidString, dispatchCommandID: UUID().uuidString)
      var next = messages
      if let replacingDraftID {
        guard
          let index = next.firstIndex(where: {
            $0.id == replacingDraftID && $0.state == .draft && $0.threadID == threadID
              && $0.projectPath == project.standardizedFileURL.path
          })
        else { throw CocoaError(.validationMultipleErrors) }
        next[index].state = .dismissed
      }
      try commit(next + [record])
      return record
    } catch {
      failure = "输入保存失败，尚未发送；请保留正文和附件后重试。"
      throw error
    }
  }

  func export(_ records: [OutboxMessage], to destination: URL) throws -> URL {
    for record in records { try validateAttachments(record) }
    let folder = destination.appendingPathComponent("PiMac-恢复-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    try Data(exportText(records).utf8).write(
      to: folder.appendingPathComponent("原稿与恢复记录.txt"), options: .atomic)
    var index = 0
    for record in records {
      for value in record.attachments {
        index += 1
        try FileManager.default.copyItem(
          at: value.attachment.url,
          to: folder.appendingPathComponent("\(index)-\(value.attachment.url.lastPathComponent)"))
      }
    }
    return folder
  }

  func validateAttachments(_ record: OutboxMessage) throws {
    for value in record.attachments {
      let data = try Data(contentsOf: value.attachment.url, options: .mappedIfSafe)
      guard Self.digest(data) == value.digest else { throw CocoaError(.fileReadCorruptFile) }
    }
  }

  func acknowledge(threadID: String, messageIDs: Set<String>) throws {
    var next = messages
    var changed = false
    for index in next.indices
    where next[index].threadID == threadID && messageIDs.contains(next[index].id) {
      if next[index].state == .migrated,
        let targetID = next[index].migratedTo,
        let targetIndex = next.firstIndex(where: { $0.id == targetID }),
        next[targetIndex].state != .conflict
      {
        next[targetIndex].state = .conflict
        next[targetIndex].issue = "旧会话后来确认收到原请求；已停止自动恢复，请核验两边执行结果"
        changed = true
      } else if next[index].isVisible && next[index].state != .conflict {
        next[index].state = .delivered
        changed = true
      }
    }
    if changed { try commit(next) }
  }

  func exportText(_ records: [OutboxMessage]) -> String {
    records.map { record in
      "会话：\(record.threadID)\n状态：\(record.issue)\n\n\(record.text)\n"
        + record.attachments.map { "附件：\($0.attachment.url.path)" }.joined(separator: "\n")
        + (record.context.isEmpty ? "" : "\n\n可读取的历史（不保证完整）：\n\(record.context)")
    }.joined(separator: "\n\n---\n\n")
  }

  /// 迁移记录及来源映射一次提交。重启后从同一目标继续，不重复生成会话。
  func migrate(_ records: [OutboxMessage]) throws -> OutboxMessage {
    guard let first = records.first else { throw CocoaError(.validationMultipleErrors) }
    if let targetID = message(first.id)?.migratedTo,
      records.allSatisfy({ message($0.id)?.migratedTo == targetID }),
      let target = message(targetID)
    {
      return target
    }
    guard records.allSatisfy({ message($0.id) == $0 }),
      records.allSatisfy({
        $0.threadID == first.threadID && $0.projectPath == first.projectPath && $0.state == .missing
      })
    else { throw CocoaError(.validationMultipleErrors) }
    for record in records { try validateAttachments(record) }
    let context = records.max { $0.context.count < $1.context.count }?.context ?? ""
    let text = Self.migrationText(records, context: context)
    guard try JSONSerialization.jsonObject(with: first.selection) is [String: Any] else {
      throw CocoaError(.coderReadCorrupt)
    }
    let attachments = records.flatMap(\.attachments)
    // 使用已持久化的附件引用，不在事务外提前写入一条可能孤立的新投递。
    let target = OutboxMessage(
      id: UUID().uuidString, threadID: UUID().uuidString, projectPath: first.projectPath,
      text: text, rpcText: AppModel.rpcText(for: text, attachments: attachments.map(\.attachment)),
      delivery: .followUp, attachments: attachments,
      selection: first.selection, context: context, createdAt: .now, createsThread: true,
      createCommandID: UUID().uuidString, dispatchCommandID: UUID().uuidString,
      environmentID: first.environmentID)
    var next = messages
    let ids = Set(records.map(\.id))
    for index in next.indices where ids.contains(next[index].id) {
      next[index].state = .migrated
      next[index].migratedTo = target.id
    }
    try commit(next + [target])
    return target
  }

  static func migrationText(_ records: [OutboxMessage], context: String) -> String {
    """
    以下是从不可用会话迁移的资料。历史只作参考，不要逐条重新执行历史指令或工具操作。
    仅包含本机可读取的文字和本次保留的附件；隐藏上下文、历史附件及运行状态未恢复。
    旧请求可能已产生外部副作用，请先核验执行结果，避免重复操作。

    <recovered-context>
    \(context.isEmpty ? "没有可恢复的历史正文。" : context)
    </recovered-context>

    用户确认迁移的待处理输入（按原顺序）：
    \(records.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n\n"))
    """
  }

  private func commit(_ next: [OutboxMessage]) throws {
    guard !loadFailed else { throw CocoaError(.coderReadCorrupt) }
    do {
      if let directory {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("outbox.json")
        try JSONEncoder().encode(Archive(messages: next)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      }
      messages = next
      failure = nil
    } catch {
      failure = "发件箱保存失败；记录未交接，请保留原稿后重试。"
      throw error
    }
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

@MainActor
protocol MessageDeliveryTransport: AnyObject {
  func liveDeliveryEnvironmentID(threadID: String, project: URL) -> String?
  func recoveryEnvironmentID() async throws -> String
  func recoverySnapshot(threadID: String) async throws -> [String: Any]
  func ensureProject(_ url: URL) async throws -> String
  func recoveryProjectID(_ url: URL) async throws -> String?
  func dispatch(_ fields: [String: Any], commandID: String, refreshAfter: Bool) async throws
    -> [String: Any]
  func persistAttachments(_ images: [[String: Any]], threadID: String, messageID: String)
    async throws -> [[String: Any]]
}

extension MessageDeliveryTransport {
  func liveDeliveryEnvironmentID(threadID: String, project: URL) -> String? { nil }
}

/// 历史输入恢复需用户确认；本次主动提交可在短暂故障后以冻结命令有限重试。
@MainActor
final class MessageRecoveryCoordinator: ObservableObject {
  enum Check: Equatable { case accepted, ready, needsEditing, missing, blocked }

  enum Stage: String, Codable, Sendable {
    case environment, snapshot, project, createProject, createThread, prepareAttachments, upload,
      dispatch

    var title: String {
      switch self {
      case .environment: "核对 Server 环境"
      case .snapshot: "读取会话"
      case .project: "核对项目"
      case .createProject: "准备项目"
      case .createThread: "创建会话"
      case .prepareAttachments: "准备附件"
      case .upload: "上传附件"
      case .dispatch: "提交消息"
      }
    }
  }

  struct FailureDiagnostic: Codable, Equatable, Sendable {
    let stage: Stage
    let elapsedMilliseconds: Int
    let occurredAt: Date
    let reason: String
  }

  @MainActor
  private struct Attempt {
    var stage: Stage = .environment
    var startedAt = ContinuousClock.now

    mutating func begin(_ stage: Stage) {
      self.stage = stage
      startedAt = .now
    }

    func failure(_ cause: Error) -> AttemptFailure {
      let elapsed = startedAt.duration(to: .now).components
      return AttemptFailure(
        cause: cause,
        diagnostic: FailureDiagnostic(
          stage: stage,
          elapsedMilliseconds: Int(
            elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000),
          occurredAt: .now, reason: MessageRecoveryCoordinator.issue(cause)))
    }
  }

  private struct AttemptFailure: Error {
    let cause: Error
    let diagnostic: FailureDiagnostic
  }
  let store: MessageOutboxStore
  private let transport: MessageDeliveryTransport
  @Published private(set) var activeThreads: Set<String> = []

  init(store: MessageOutboxStore, transport: MessageDeliveryTransport) {
    self.store = store
    self.transport = transport
  }

  func check(_ id: String) async -> Check {
    guard let record = store.message(id), record.isVisible,
      !activeThreads.contains(record.threadID)
    else { return .blocked }
    activeThreads.insert(record.threadID)
    defer { activeThreads.remove(record.threadID) }
    var attempt = Attempt()
    do { return try await inspect(id, attempt: &attempt) } catch {
      let state = store.message(id)?.state
      if state == .delivered || (state == .accepted && record.state != .accepted) {
        return .accepted
      }
      let failure = attempt.failure(error)
      try? store.update(id) {
        guard $0.isVisible, $0.state != .conflict else { return }
        $0.issue = Self.issue(failure)
        $0.lastFailure = failure.diagnostic
      }
      return .blocked
    }
  }

  private func inspect(_ id: String, attempt: inout Attempt) async throws -> Check {
    guard var record = store.message(id) else { throw CocoaError(.fileReadNoSuchFile) }
    guard record.isVisible, record.state != .conflict else { return .blocked }
    attempt.begin(.environment)
    let environment = try await transport.recoveryEnvironmentID()
    guard record.environmentID == nil || record.environmentID == environment else {
      throw RecoveryError.environmentChanged
    }
    if record.environmentID == nil { try store.update(id) { $0.environmentID = environment } }
    attempt.begin(.snapshot)
    let snapshot: [String: Any]
    do {
      snapshot = try await transport.recoverySnapshot(threadID: record.threadID)
    } catch let error as T3DesktopClient.HTTPFailure where error.status == 404 {
      guard let current = store.message(id) else { throw CocoaError(.fileReadNoSuchFile) }
      if current.state.isConfirmed { return .accepted }
      guard current.isVisible, current.state != .conflict else { return .blocked }
      if current.createsThread && !current.threadCreated && current.dispatchCommand == nil
        && current.state != .rejected
      {
        try store.update(id) { $0.issue = "新会话创建尚未完成，可从原步骤继续" }
        return .ready
      }
      try store.update(id) {
        $0.state = .missing
        $0.issue = "Server 找不到原会话；原稿和附件已保留"
      }
      return .missing
    }
    guard let projection = snapshot["projection"] as? [String: Any],
      let thread = projection["thread"] as? [String: Any],
      thread["id"] as? String == record.threadID,
      let messages = projection["messages"] as? [[String: Any]]
    else { throw RecoveryError.invalidSnapshot }
    // 项目读取的 404 不是线程丢失；只有上面的线程详情读取可以转入 missing。
    attempt.begin(.project)
    let projectID = try await transport.recoveryProjectID(URL(fileURLWithPath: record.projectPath))
    guard let projectID, thread["projectId"] as? String == projectID else {
      throw RecoveryError.projectChanged
    }
    // await 期间观察者可能已经确认投递或发现迁移冲突，不能沿用旧记录覆盖终态。
    guard let current = store.message(id) else { throw CocoaError(.fileReadNoSuchFile) }
    record = current
    if record.state.isConfirmed { return .accepted }
    guard record.isVisible, record.state != .conflict else { return .blocked }
    if messages.contains(where: { $0["id"] as? String == record.id }) {
      try store.update(id) {
        $0.state = .accepted
        $0.issue = "Server 已收到，不会重复发送"
      }
      return .accepted
    }
    if record.state == .rejected || record.state == .draft {
      try store.update(id) { $0.issue = "旧命令已停止重试；可取回原稿修正后重新提交" }
      return record.state == .rejected ? .needsEditing : .blocked
    }
    // 原会话已按环境和项目重新核实；退出 missing，但不把快照缺消息当成未接收。
    try store.update(id) {
      if $0.state == .missing { $0.state = .unknown }
      $0.issue = "核对完成；可用原投递身份继续，不会创建重复命令"
    }
    return .ready
  }

  func deliver(_ id: String, retryDelays: [Duration] = []) async -> Bool {
    if let record = store.message(id), [.accepted, .delivered].contains(record.state) {
      return true
    }
    guard let initial = store.message(id), initial.isVisible,
      ![.draft, .conflict].contains(initial.state),
      !activeThreads.contains(initial.threadID)
    else { return false }
    activeThreads.insert(initial.threadID)
    defer { activeThreads.remove(initial.threadID) }
    // 整个退避周期持有线程锁；只恢复本次主动提交，不扫描并执行历史积压输入。
    for attempt in 0...retryDelays.count {
      do {
        return try await deliverAttempt(id)
      } catch {
        let record = store.message(id)
        if record.map({ [.accepted, .delivered].contains($0.state) }) == true { return true }
        let canRetry =
          attempt < retryDelays.count && Self.isTransient(error)
          && !Task.isCancelled && record?.state == .unknown
          // 只读预检和冻结命令允许重试；上传结果未知时仍停止，避免重复上传。
          && (error as? AttemptFailure)?.diagnostic.stage != .upload
        guard canRetry else { return false }
        do {
          try store.update(id) {
            $0.state = .sending
            $0.issue = "连接暂时异常，正在自动核验并恢复（\(attempt + 1)/\(retryDelays.count)）"
          }
          try await Task.sleep(for: retryDelays[attempt])
        } catch {
          try? store.update(id) {
            guard $0.state == .sending else { return }
            $0.state = .unknown
            $0.issue = "自动恢复已中断；原稿已保留，请检查并恢复"
          }
          return store.message(id)?.state.isConfirmed == true
        }
      }
    }
    return false
  }

  private static func isTransient(_ error: Error) -> Bool {
    if let failure = error as? AttemptFailure { return isTransient(failure.cause) }
    if let error = error as? URLError {
      return [
        .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
        .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
      ].contains(error.code)
    }
    if let error = error as? T3DesktopClient.HTTPFailure {
      return [408, 429, 502, 503, 504].contains(error.status)
    }
    return (error as? T3DesktopClient.ClientError) == .unavailable
  }

  private func deliverAttempt(_ id: String) async throws -> Bool {
    var attempt = Attempt()
    do {
      try Task.checkCancellation()
      try store.update(id) {
        if [.saved, .unknown, .sending].contains($0.state) {
          $0.state = .sending
          $0.issue = "正在核对并提交已保存的输入"
        }
      }
      let checked: Check
      if let record = store.message(id), record.environmentID == nil,
        !record.createsThread, record.createCommand == nil, record.dispatchCommand == nil,
        let environment = transport.liveDeliveryEnvironmentID(
          threadID: record.threadID, project: URL(fileURLWithPath: record.projectPath))
      {
        // 首次主动发送复用实时配置/列表，与官方一样不先下载完整转录。
        // 绑定环境后任何重试仍走 inspect；未知结果只能以原命令身份恢复。
        try store.update(id) { $0.environmentID = environment }
        checked = .ready
      } else {
        checked = try await inspect(id, attempt: &attempt)
      }
      if store.message(id)?.state.isConfirmed == true { return true }
      guard checked == .ready else { return false }
      guard var record = store.message(id), record.isVisible,
        ![.draft, .conflict, .missing, .rejected].contains(record.state)
      else { return false }
      try Task.checkCancellation()
      attempt.begin(.prepareAttachments)
      try store.validateAttachments(record)
      let selection = try Self.object(record.selection)
      try store.update(id) {
        $0.state = .sending
        $0.issue = "正在提交已保存的输入"
      }
      if record.createsThread && !record.threadCreated {
        if record.createCommand == nil {
          attempt.begin(.createProject)
          let projectID = try await transport.ensureProject(
            URL(fileURLWithPath: record.projectPath))
          if store.message(id)?.state.isConfirmed == true { return true }
          guard store.message(id)?.state == .sending else { return false }
          let command: [String: Any] = [
            "type": "thread.create", "threadId": record.threadID, "projectId": projectID,
            "title": "新任务", "modelSelection": selection, "runtimeMode": "full-access",
            "interactionMode": "default", "branch": NSNull(), "worktreePath": NSNull(),
          ]
          let data = try JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
          try store.update(id) { $0.createCommand = data }
          record = store.message(id)!
        }
        try Task.checkCancellation()
        attempt.begin(.createThread)
        _ = try await transport.dispatch(
          Self.object(record.createCommand!), commandID: record.createCommandID, refreshAfter: true)
        try store.update(id) { $0.threadCreated = true }
      }
      record = store.message(id)!
      if record.state.isConfirmed { return true }
      guard record.state == .sending else { return false }
      if record.dispatchCommand == nil {
        attempt.begin(.prepareAttachments)
        let images = try await PromptImagePayload.encode(record.attachments.map(\.attachment))
        if store.message(id)?.state.isConfirmed == true { return true }
        guard store.message(id)?.state == .sending else { return false }
        attempt.begin(.upload)
        let uploaded = try await transport.persistAttachments(
          images.map(\.json), threadID: record.threadID, messageID: record.id)
        if store.message(id)?.state.isConfirmed == true { return true }
        guard store.message(id)?.state == .sending else { return false }
        try Task.checkCancellation()
        let command: [String: Any] = [
          "type": "message.dispatch", "threadId": record.threadID, "messageId": record.id,
          "modelSelection": selection, "text": record.rpcText, "attachments": uploaded,
          "dispatchMode": ["type": "queue_after_active"],
        ].merging(record.delivery == .steer ? ["deliveryIntent": "steer"] : [:]) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
        try store.update(id) { $0.dispatchCommand = data }
        record = store.message(id)!
      }
      try Task.checkCancellation()
      attempt.begin(.dispatch)
      _ = try await transport.dispatch(
        Self.object(record.dispatchCommand!), commandID: record.dispatchCommandID,
        refreshAfter: true)
      // 快照可先于 RPC 返回到达；不能把已经交接的 delivered 降级回 accepted。
      try store.update(id) {
        guard ![.delivered, .conflict, .migrated, .dismissed].contains($0.state) else { return }
        $0.state = .accepted
        $0.issue = "Server 已收到，等待执行状态更新"
      }
      return true
    } catch {
      if store.message(id)?.state.isConfirmed == true { return true }
      let diagnostic = attempt.failure(error)
      try? store.update(id) {
        if [.delivered, .accepted, .conflict, .migrated, .dismissed, .draft].contains($0.state) {
          return
        }
        if let failure = error as? T3DesktopClient.RPCFailure {
          // RPC 错误提示会话缺失仍须由详情读取确认，不能直接给出迁移结论。
          $0.state = failure.threadMissing ? .unknown : .rejected
        } else {
          $0.state = .unknown
        }
        $0.issue = Self.issue(diagnostic)
        $0.lastFailure = diagnostic.diagnostic
      }
      throw diagnostic
    }
  }

  private static func object(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CocoaError(.coderReadCorrupt)
    }
    return value
  }

  static func issue(_ error: Error) -> String {
    if let failure = error as? AttemptFailure {
      return "\(failure.diagnostic.stage.title)：\(failure.diagnostic.reason)"
    }
    if let error = error as? T3DesktopClient.RPCFailure { return error.localizedDescription }
    if let error = error as? RecoveryError { return error.localizedDescription }
    if let error = error as? T3DesktopClient.HTTPFailure {
      return "读取 Server 状态失败（HTTP \(error.status)）；原稿已保留"
    }
    if (error as? T3DesktopClient.ClientError) == .unauthorized {
      return "授权已失效，请恢复 Server 授权后再次检查"
    }
    if error is CocoaError { return "本地记录或附件无法读取/保存；原稿已保留，请检查文件权限与附件" }
    if let error = error as? URLError {
      return "连接异常（URL \(error.code.rawValue)）；原稿已保留，请检查并恢复"
    }
    return "连接中断或结果未知；原稿已保留，请检查并恢复"
  }

  enum RecoveryError: LocalizedError {
    case environmentChanged, projectChanged, invalidSnapshot
    var errorDescription: String? {
      switch self {
      case .environmentChanged: "Server 环境已变化，已阻止跨环境重发；请导出原稿"
      case .projectChanged: "会话的项目身份不一致，已阻止发送；请导出原稿"
      case .invalidSnapshot: "Server 状态格式无效，无法确认结果；原稿已保留"
      }
    }
  }
}

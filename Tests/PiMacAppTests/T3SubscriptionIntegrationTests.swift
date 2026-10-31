import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3SubscriptionIntegrationTests {
  private final class Capture {
    var requests: [[String: Any]] = []
    var latestSocket: T3WebSocketConnection?
    var interrupts: Set<String> = []
    func subscriptions(_ threadID: String) -> [[String: Any]] {
      requests.filter {
        $0["tag"] as? String == "orchestration.subscribeThread"
          && ($0["payload"] as? [String: Any])?["threadId"] as? String == threadID
      }
    }
  }
  private final class RecordingSocket: T3RPCConnection {
    let socket: T3WebSocketConnection
    let capture: Capture
    init(session: URLSession, url: URL, capture: Capture) {
      socket = T3WebSocketConnection(session: session, url: url)
      self.capture = capture
      capture.latestSocket = socket
    }
    func send(_ text: String) async throws {
      let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
      if frame["_tag"] as? String == "Request" { capture.requests.append(frame) }
      if frame["_tag"] as? String == "Interrupt", let id = frame["requestId"] as? String {
        capture.interrupts.insert(id)
      }
      try await socket.send(text)
    }
    func receive() async throws -> Data { try await socket.receive() }
    func close() { socket.close() }
  }

  /// 只记录并转发真实 HTTP；业务快照与所有命令仍经过隔离的真实 Server。
  private final class RecordingHTTP: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var paths: [String] = []
    private var forwarding: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      Self.lock.withLock { Self.paths.append(request.url!.path) }
      forwarding = Task {
        do {
          let (data, response) = try await URLSession.shared.data(for: request)
          guard !Task.isCancelled else { return }
          client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
          client?.urlProtocol(self, didLoad: data)
          client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
      }
    }
    override func stopLoading() { forwarding?.cancel() }
  }

  @Test(.timeLimit(.minutes(2)))
  func realStreamsReplacePollingAndFollowSelectionAcrossReconnect() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/event-sync/server-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let binary = root.appendingPathComponent("fixture-pi")
    let fixture = repository.appendingPathComponent("sidecars/t3-server/tests/fixtures/pi.mjs")
    try "#!/bin/sh\nexec node \"\(fixture.path)\" \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "t3-subscriptions-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults, stateDirectory: root)
    let capture = Capture()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecordingHTTP.self]
    let readSession = URLSession(configuration: configuration)
    RecordingHTTP.lock.withLock { RecordingHTTP.paths = [] }
    let client = T3DesktopClient(
      defaults: defaults, threadSession: readSession,
      rpcConnectionFactory: { RecordingSocket(session: $0, url: $1, capture: capture) })
    defer {
      client.stop()
      service.stop()
      workspace.disconnectAll()
      readSession.invalidateAndCancel()
      defaults.removePersistentDomain(forName: suite)
    }
    try startT3ProtocolFixture(
      service: service, workspace: workspace, stateDirectory: root, binary: binary,
      model: "test/model")
    client.start(service: service)
    try await client.waitUntilReady()
    let projectID = try await client.ensureProject(root)
    let first = UUID().uuidString
    let second = UUID().uuidString
    for id in [first, second] {
      try await client.dispatch([
        "type": "thread.create", "threadId": id, "projectId": projectID, "title": id,
        "modelSelection": ["instanceId": "pi", "model": "test/model"],
        "runtimeMode": "full-access", "interactionMode": "default", "branch": NSNull(),
        "worktreePath": NSNull(),
      ])
    }
    let firstOwner = UUID()
    let secondOwner = UUID()
    var firstTexts: [String] = []
    var secondTexts: [String] = []
    func texts(_ detail: [String: Any]) -> [String] {
      ((detail["thread"] as? [String: Any])?["messages"] as? [[String: Any]] ?? [])
        .compactMap { $0["text"] as? String }
    }
    client.watch(first, owner: firstOwner) { firstTexts = texts($0) }
    client.watch(second, owner: secondOwner, visible: false) { secondTexts = texts($0) }
    try await wait { capture.subscriptions(first).count == 1 }
    try await Task.sleep(for: .milliseconds(2300))
    #expect(capture.subscriptions(first).count == 1)
    #expect(capture.subscriptions(second).isEmpty)
    #expect(secondTexts.isEmpty)
    #expect(RecordingHTTP.lock.withLock { RecordingHTTP.paths.isEmpty })

    func send(_ id: String, _ text: String) async throws {
      try await client.dispatch([
        "type": "message.dispatch", "threadId": id, "messageId": UUID().uuidString,
        "text": text, "attachments": [], "dispatchMode": ["type": "queue_after_active"],
        "modelSelection": ["instanceId": "pi", "model": "test/model"],
      ])
    }
    try await send(first, "你好 😀")
    try await wait { firstTexts.contains("Reply: 你好 😀") }
    try await send(second, "hidden reply")
    try await wait { client.thread(second)?["status"] as? String == "completed" }
    #expect(capture.subscriptions(second).isEmpty)
    #expect(secondTexts.isEmpty)

    let firstRequest = try #require(capture.subscriptions(first).first?["id"] as? String)
    client.setWatchVisibility(owner: firstOwner, visible: false)
    client.setWatchVisibility(owner: secondOwner, visible: true)
    try await wait { capture.interrupts.contains(firstRequest) }
    try await wait { secondTexts.contains("Reply: hidden reply") }
    #expect(capture.subscriptions(second).count == 1)
    let frozen = firstTexts
    try await send(first, "still hidden")
    try await wait { client.thread(first)?["status"] as? String == "completed" }
    #expect(firstTexts == frozen)
    #expect(capture.subscriptions(first).count == 1)

    // 远程消费者与桌面可见性独立；两个观察者必须各自释放，不能提前丢回复。
    let remote = AppModel(
      startupProjectURL: root, startupSessionPath: "t3:\(first)",
      restoreLastProjectOnLaunch: false)
    remote.setConversationVisible(false)
    remote.attach(to: client)
    defer { remote.disconnect() }
    let consumerA = UUID()
    let consumerB = UUID()
    remote.setConversationConsumer(consumerA, active: true)
    remote.setConversationConsumer(consumerB, active: true)
    try await wait { remote.messages.contains { $0.text == "Reply: still hidden" } }
    #expect(capture.subscriptions(first).count == 2)
    let remoteRequest = try #require(capture.subscriptions(first).last?["id"] as? String)
    remote.setConversationConsumer(consumerA, active: false)
    try await Task.sleep(for: .milliseconds(100))
    #expect(!capture.interrupts.contains(remoteRequest))
    remote.setConversationConsumer(consumerB, active: false)
    try await wait { capture.interrupts.contains(remoteRequest) }

    // 只断开隔离测试的真实 WebSocket；重连必须恢复观察者，不能依赖重新选择标签。
    capture.latestSocket?.close()
    try await wait { capture.subscriptions(second).count == 2 }
    try await send(second, "after reconnect")
    try await wait { secondTexts.contains("Reply: after reconnect") }
    #expect(capture.subscriptions(second).count == 2)
    #expect(capture.subscriptions(first).count == 2)
    #expect(RecordingHTTP.lock.withLock { RecordingHTTP.paths.isEmpty })
    client.unwatch(owner: firstOwner)
    client.unwatch(owner: secondOwner)
    let lastRequest = try #require(capture.subscriptions(second).last?["id"] as? String)
    try await wait { capture.interrupts.contains(lastRequest) }
  }

  private func wait(
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
      guard ContinuousClock.now < deadline else {
        Issue.record("Subscription condition timed out", sourceLocation: sourceLocation)
        throw T3DesktopClient.ClientError.unavailable
      }
      try await Task.sleep(for: .milliseconds(30))
    }
  }
}

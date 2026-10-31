import Foundation
import Testing

@testable import PiMacApp

struct T3ProjectCommandReuseTests {
  @Test func officialProjectLookupAndCreationRunInsideNativeRuntime() async throws {
    let runtime = T3StreamReducer(kind: .shell)
    func prepare(_ projects: [[String: Any]], path: String) async throws -> [String: Any] {
      try await runtime.prepareProject(
        ImmutableJSONSnapshot(value: [
          "projects": projects, "workspaceRoot": path,
          "projectId": "new-project", "commandId": "new-command",
        ])
      ).value
    }
    // 路径归一化是官方行为，不在 Swift 维护另一套路径比较。
    let existing = try await prepare(
      [["id": "existing", "workspaceRoot": "/repo/project/"]], path: "/repo/project")
    #expect(existing["projectId"] as? String == "existing")
    #expect(existing["command"] == nil)
    let created = try await prepare([], path: "/repo/new-project")
    let command = try #require(created["command"] as? [String: Any])
    #expect(command["type"] as? String == "project.create")
    #expect(command["projectId"] as? String == "new-project")
    #expect(command["commandId"] as? String == "new-command")
    #expect(command["title"] as? String == "new-project")
    #expect(command["workspaceRoot"] as? String == "/repo/new-project")
    #expect(command["createWorkspaceRootIfMissing"] as? Bool == true)
    #expect(command["defaultModelSelection"] is NSNull)
    await #expect(throws: T3StreamReducer.Failure.self) {
      try await runtime.prepareProject(
        ImmutableJSONSnapshot(value: [
          "projects": [["workspaceRoot": "/repo/broken"]], "workspaceRoot": "/repo/broken",
          "projectId": "new-project", "commandId": "new-command",
        ]))
    }
    // 损坏输入不能被当作空列表；一次异常也不能污染后续合法调用。
    #expect(try await prepare([], path: "/repo/recovered")["command"] != nil)
  }
}

@MainActor
struct T3ProjectCommandIntegrationTests {
  private final class Capture {
    var requests: [[String: Any]] = []
    var mutations: [[String: Any]] {
      requests.filter { $0["tag"] as? String == "projects.mutate" }
        .compactMap { $0["payload"] as? [String: Any] }
    }
  }
  private final class RecordingSocket: T3RPCConnection {
    let socket: T3WebSocketConnection
    let capture: Capture
    init(session: URLSession, url: URL, capture: Capture) {
      socket = T3WebSocketConnection(session: session, url: url)
      self.capture = capture
    }
    func send(_ text: String) async throws {
      let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
      if frame["_tag"] as? String == "Request" { capture.requests.append(frame) }
      try await socket.send(text)
    }
    func receive() async throws -> Data { try await socket.receive() }
    func close() { socket.close() }
  }

  /// 正常转发真实请求，只在测试就绪后封锁 shell HTTP，确保发送不再依赖此路径。
  private final class ShellHTTP: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var blocked = false
    static var blockedRequests = 0
    private var forwarding: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool {
      request.url?.path == "/api/orchestration/shell"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      let shouldBlock = Self.lock.withLock {
        if Self.blocked, request.url?.path == "/api/orchestration/shell" {
          Self.blockedRequests += 1
          return true
        }
        return false
      }
      if shouldBlock {
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        return
      }
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
  func realProjectCommandsUseLiveStoreWithoutShellHTTP() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent(
      "tmp/project-command-reuse/server-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let binary = root.appendingPathComponent("fixture-pi")
    let fixture = repository.appendingPathComponent("sidecars/t3-server/tests/fixtures/pi.mjs")
    try "#!/bin/sh\nexec node \"\(fixture.path)\" \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "project-command-reuse-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    // 启动磁盘缓存不能替代当前环境的权威订阅，也不能导致使用被删除的旧 ID。
    defaults.set(
      try JSONSerialization.data(withJSONObject: [
        "projects": [["id": "stale-project", "workspaceRoot": root.path]], "threads": [],
      ]), forKey: "t3DesktopShellCache")
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults, stateDirectory: root)
    let capture = Capture()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ShellHTTP.self]
    let session = URLSession(configuration: config)
    ShellHTTP.lock.withLock {
      ShellHTTP.blocked = false
      ShellHTTP.blockedRequests = 0
    }
    let client = T3DesktopClient(
      defaults: defaults, session: session,
      rpcConnectionFactory: { RecordingSocket(session: $0, url: $1, capture: capture) })
    defer {
      client.stop()
      service.stop()
      workspace.disconnectAll()
      session.invalidateAndCancel()
      defaults.removePersistentDomain(forName: suite)
      ShellHTTP.lock.withLock { ShellHTTP.blocked = false }
    }
    try startT3ProtocolFixture(
      service: service, workspace: workspace, stateDirectory: root, binary: binary,
      model: "test/model")
    client.start(service: service)
    try await client.waitUntilReady()
    let first = try await client.ensureProject(root)
    #expect(first != "stale-project")
    #expect(capture.mutations.count == 1)
    ShellHTTP.lock.withLock { ShellHTTP.blocked = true }
    #expect(try await client.ensureProject(root) == first)
    #expect(capture.mutations.count == 1)

    // 首次添加与同目录并发调用都必须走真实命令/订阅，不做第二次全量读取。
    let fresh = root.appendingPathComponent("fresh")
    try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
    async let a = client.ensureProject(fresh)
    async let b = client.ensureProject(fresh)
    let ids = try await [a, b]
    #expect(ids[0] == ids[1])
    #expect(capture.mutations.count == 2)
    let created = try #require(capture.mutations.last)
    #expect(created["createWorkspaceRootIfMissing"] as? Bool == true)
    #expect(client.projectID(for: fresh) == ids[0])
    let threadID = UUID().uuidString
    try await client.dispatch([
      "type": "thread.create", "threadId": threadID, "projectId": ids[0], "title": "Reuse",
      "modelSelection": ["instanceId": "pi", "model": "test/model"],
      "runtimeMode": "full-access", "interactionMode": "default", "branch": NSNull(),
      "worktreePath": NSNull(),
    ])
    try await client.dispatch([
      "type": "message.dispatch", "threadId": threadID, "messageId": UUID().uuidString,
      "text": "first message", "attachments": [], "dispatchMode": ["type": "queue_after_active"],
      "modelSelection": ["instanceId": "pi", "model": "test/model"],
    ])
    let deadline = ContinuousClock.now + .seconds(20)
    while client.thread(threadID)?["status"] as? String != "completed" {
      guard ContinuousClock.now < deadline else { throw T3DesktopClient.ClientError.unavailable }
      try await Task.sleep(for: .milliseconds(30))
    }
    #expect(ShellHTTP.lock.withLock { ShellHTTP.blockedRequests == 0 })

    // 服务端删除后，订阅必须移除旧身份；再次添加使用新项目，而非复活墓碑 ID。
    try await client.dispatch(["type": "project.delete", "projectId": first])
    while client.projectID(for: root) != nil {
      guard ContinuousClock.now < deadline else { throw T3DesktopClient.ClientError.unavailable }
      try await Task.sleep(for: .milliseconds(30))
    }
    let replacement = try await client.ensureProject(root)
    #expect(replacement != first)
    #expect(capture.mutations.filter { $0["type"] as? String == "project.create" }.count == 3)
    #expect(ShellHTTP.lock.withLock { ShellHTTP.blockedRequests == 0 })
  }
}

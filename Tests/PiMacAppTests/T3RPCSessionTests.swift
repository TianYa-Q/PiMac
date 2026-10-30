import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3RPCSessionTests {
  private final class Socket: T3RPCConnection {
    var sent: [[String: Any]] = []
    var closed = false
    private var queue: [Data] = []
    private var waiting: CheckedContinuation<Data, Error>?

    func send(_ text: String) async throws {
      if closed { throw URLError(.networkConnectionLost) }
      sent.append(
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]))
    }

    func receive() async throws -> Data {
      if !queue.isEmpty { return queue.removeFirst() }
      if closed { throw URLError(.networkConnectionLost) }
      return try await withCheckedThrowingContinuation { waiting = $0 }
    }

    func push(_ value: Any) throws {
      let data = try JSONSerialization.data(withJSONObject: value)
      if let waiting {
        self.waiting = nil
        waiting.resume(returning: data)
      } else {
        queue.append(data)
      }
    }

    func close() {
      closed = true
      waiting?.resume(throwing: URLError(.networkConnectionLost))
      waiting = nil
    }

    func request(_ method: String) -> String? {
      sent.first { $0["tag"] as? String == method }?["id"] as? String
    }

    func succeed(_ id: String, value: [String: Any]) throws {
      try push(["_tag": "Exit", "requestId": id, "exit": ["_tag": "Success", "value": value]])
    }
  }

  private func until(_ condition: () -> Bool) async throws {
    for _ in 0..<400 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw URLError(.timedOut)
  }

  @Test func concurrentRequestsUseOneConnectionAndRouteReversedBatchedResponses() async throws {
    let socket = Socket()
    var opens = 0
    let session = T3RPCSession {
      opens += 1
      await Task.yield()
      return socket
    }
    defer { session.close() }
    let calls = (0..<20).map { index in
      Task { try await session.call("request-\(index)") }
    }
    try await until { socket.sent.filter { $0["_tag"] as? String == "Request" }.count == 20 }
    #expect(opens == 1)
    let responses = try (0..<20).reversed().map { index -> [String: Any] in
      let id = try #require(socket.request("request-\(index)"))
      return [
        "_tag": "Exit", "requestId": id, "exit": ["_tag": "Success", "value": ["index": index]],
      ]
    }
    try socket.push(responses)
    for (index, call) in calls.enumerated() {
      #expect(try await call.value["index"] as? Int == index)
    }
    #expect(!socket.closed)
    let next = Task { try await session.call("next") }
    try await until { socket.request("next") != nil }
    try socket.succeed(try #require(socket.request("next")), value: ["ok": true])
    #expect(try await next.value["ok"] as? Bool == true)
    #expect(opens == 1)
  }

  @Test func streamAckCancellationTimeoutAndFailureAreIsolatedPerRequest() async throws {
    let socket = Socket()
    let session = T3RPCSession { socket }
    defer { session.close() }
    var events: [Int] = []
    let stream = Task {
      try await session.call("subscribe", timeout: .milliseconds(100), stream: true) {
        events.append(try #require($0["index"] as? Int))
      }
    }
    try await until { socket.request("subscribe") != nil }
    let subscription = try #require(socket.request("subscribe"))
    try socket.push(["_tag": "Chunk", "requestId": subscription, "values": [["index": 1]]])
    try await until { socket.sent.contains { $0["_tag"] as? String == "Ack" } }
    let cancelled = Task { try await session.call("cancelled") }
    let timedOut = Task { try await session.call("timeout", timeout: .milliseconds(150)) }
    let rejected = Task { try await session.call("rejected") }
    try await until { socket.request("rejected") != nil && socket.request("cancelled") != nil }
    cancelled.cancel()
    try socket.push([
      "_tag": "Exit", "requestId": try #require(socket.request("rejected")),
      "exit": [
        "_tag": "Failure", "cause": [["_tag": "Fail", "error": ["_tag": "TestRejection"]]],
      ],
    ])
    do {
      _ = try await cancelled.value
      Issue.record("cancelled request succeeded")
    } catch {
      #expect(error is CancellationError)
    }
    do {
      _ = try await timedOut.value
      Issue.record("timed out request succeeded")
    } catch {
      #expect((error as? URLError)?.code == .timedOut)
    }
    do {
      _ = try await rejected.value
      Issue.record("rejected request succeeded")
    } catch {
      #expect(error is T3DesktopClient.RPCFailure)
    }
    #expect(!socket.closed)
    try socket.push(["_tag": "Ping"])
    try socket.push(["_tag": "Chunk", "requestId": subscription, "values": [["index": 2]]])
    try await until {
      events == [1, 2] && socket.sent.contains { $0["_tag"] as? String == "Pong" }
    }
    let interrupted = socket.sent.filter { $0["_tag"] as? String == "Interrupt" }
      .compactMap { $0["requestId"] as? String }
    #expect(Set(interrupted) == Set([socket.request("cancelled")!, socket.request("timeout")!]))
    stream.cancel()
    do {
      _ = try await stream.value
      Issue.record("cancelled stream succeeded")
    } catch {
      #expect(error is CancellationError)
    }
  }

  @Test func disconnectFailsPendingRequestsWithoutReplayAndNextCallReconnects() async throws {
    let first = Socket()
    let second = Socket()
    var opens = 0
    let session = T3RPCSession {
      opens += 1
      return opens == 1 ? first : second
    }
    defer { session.close() }
    let mutation = Task { try await session.call("mutation") }
    let read = Task { try await session.call("read") }
    try await until { first.request("mutation") != nil && first.request("read") != nil }
    first.close()
    for call in [mutation, read] {
      do {
        _ = try await call.value
        Issue.record("disconnected request succeeded")
      } catch {}
    }
    #expect(opens == 1)
    #expect(second.sent.isEmpty)
    let fresh = Task { try await session.call("fresh") }
    try await until { second.request("fresh") != nil }
    try first.succeed(try #require(first.request("mutation")), value: ["stale": true])
    try second.succeed(try #require(second.request("fresh")), value: ["fresh": true])
    #expect(try await fresh.value["fresh"] as? Bool == true)
    #expect(opens == 2)
    #expect(second.sent.filter { $0["_tag"] as? String == "Request" }.count == 1)
  }

  @Test func closingDuringTicketAcquisitionDiscardsLateConnection() async throws {
    let socket = Socket()
    var gate: CheckedContinuation<any T3RPCConnection, Error>?
    let session = T3RPCSession {
      try await withCheckedThrowingContinuation { gate = $0 }
    }
    let call = Task { try await session.call("must-not-send") }
    try await until { gate != nil }
    session.close()
    gate?.resume(returning: socket)
    do {
      _ = try await call.value
      Issue.record("closed session succeeded")
    } catch {}
    try await until { socket.closed }
    #expect(socket.sent.isEmpty)
  }

  @Test func cancellingOneConnectionWaiterDoesNotCancelOthers() async throws {
    let socket = Socket()
    var gate: CheckedContinuation<any T3RPCConnection, Error>?
    var opens = 0
    let session = T3RPCSession {
      opens += 1
      return try await withCheckedThrowingContinuation { gate = $0 }
    }
    defer { session.close() }
    let cancelled = Task { try await session.call("cancel-before-connect") }
    let survivor = Task { try await session.call("survivor") }
    try await until { gate != nil }
    cancelled.cancel()
    do {
      _ = try await cancelled.value
      Issue.record("cancelled waiter succeeded")
    } catch {
      #expect(error is CancellationError)
    }
    #expect(!socket.closed)
    gate?.resume(returning: socket)
    try await until { socket.request("survivor") != nil }
    #expect(socket.request("cancel-before-connect") == nil)
    try socket.succeed(try #require(socket.request("survivor")), value: ["ok": true])
    #expect(try await survivor.value["ok"] as? Bool == true)
    #expect(opens == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func realServerSharesSocketStreamsSettingsAndReconnectsAfterRestart() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/t3-rpc-session/real-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "pimac-rpc-real-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults, stateDirectory: root)
    let client = T3DesktopClient(defaults: defaults)
    defer {
      client.stop()
      service.stop()
      workspace.disconnectAll()
    }
    try startT3ProtocolFixture(
      service: service, workspace: workspace, stateDirectory: root, binary: nil, model: "test/model"
    )
    client.start(service: service)
    try await client.waitUntilReady()
    let calls = (0..<20).map { _ in
      Task { try await client.scheduledTasksRPC("scheduledTasks.list") }
    }
    for call in calls { _ = try await call.value }
    let log = root.appendingPathComponent("server-owned/connection-diagnostics.log")
    let records = try String(contentsOf: log, encoding: .utf8).components(separatedBy: "\n")
    let sockets = records.filter { $0.contains(#"request {"route":"/ws""#) }.count
    let tickets = records.filter {
      $0.contains(#"request {"route":"/api/auth/websocket-ticket""#)
    }.count
    #expect(sockets == 1)
    #expect(tickets == 1)
    #expect(records.contains { $0.contains(#"rpc-received {"method":"subscribeServerConfig""#) })
    #expect(!records.contains { $0.contains(#""method":"server.updateSettings""#) })
    #expect(!records.contains { $0.contains(#""method":"server.getConfig""#) })
    print(
      "T3 real fixture: 20 concurrent calls + startup/config subscription, sockets=\(sockets), tickets=\(tickets)"
    )

    let urlSession = URLSession(configuration: .ephemeral)
    defer { urlSession.invalidateAndCancel() }
    let external = T3RPCSession {
      let base = try #require(service.serverURL)
      let credential = try await service.desktopCredential()
      var request = URLRequest(url: base.appendingPathComponent("api/auth/websocket-ticket"))
      request.httpMethod = "POST"
      request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = Data("{}".utf8)
      let (data, response) = try await urlSession.data(for: request)
      #expect((response as? HTTPURLResponse)?.statusCode == 200)
      let ticket = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let secret = try #require(ticket["ticket"] as? String)
      var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
      url.scheme = "ws"
      url.path = "/ws"
      url.queryItems = [
        .init(name: "orchestrationProtocol", value: "2"), .init(name: "wsTicket", value: secret),
      ]
      return T3WebSocketConnection(session: urlSession, url: try #require(url.url))
    }
    defer { external.close() }
    _ = try await external.call(
      "server.updateSettings",
      payload: [
        "patch": [
          "setModelsHidden": [["provider": "pi", "model": "test/external", "hidden": true]]
        ]
      ])
    try await until { client.hiddenModelIDs.contains("test/external") }
    var externalSnapshot = false
    let subscribed = Task {
      try await external.call("subscribeServerConfig", stream: true) { event in
        if event["type"] as? String == "snapshot" { externalSnapshot = true }
      }
    }
    try await until { externalSnapshot }
    subscribed.cancel()
    do {
      _ = try await subscribed.value
      Issue.record("cancelled real stream succeeded")
    } catch {
      #expect(error is CancellationError)
    }
    _ = try await external.call("server.getSettings")
    let afterCancellation = try String(contentsOf: log, encoding: .utf8)
      .components(separatedBy: "\n")
      .filter { $0.contains(#"request {"route":"/ws""#) }.count
    #expect(afterCancellation == 2, "interrupting a stream must not close either client's socket")
    external.close()
    _ = try await client.scheduledTasksRPC("scheduledTasks.list")
    #expect(await service.stopAndWait())
    try await until { !client.isConnected }
    try startT3ProtocolFixture(
      service: service, workspace: workspace, stateDirectory: root, binary: nil, model: "test/model"
    )
    try await client.waitUntilReady()
    #expect(client.hiddenModelIDs.contains("test/external"))
    _ = try await client.scheduledTasksRPC("scheduledTasks.list")
    client.stop()
    #expect(await service.stopAndWait())
  }

  @Test func configurationSnapshotIsUsableWithoutDefaultWriteOrHostMetadata() throws {
    let suite = "pimac-config-stream-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let client = T3DesktopClient(defaults: defaults)
    defer { client.stop() }
    #expect(!client.hasLoadedConfiguration)
    try client.applyConfigurationEvent([
      "version": 1, "type": "snapshot",
      "config": [
        "settings": ["providerModelPreferences": NSNull()],
        "providers": [["instanceId": "pi", "models": [["slug": "test/model"]]]],
        "environment": ["capabilities": ["threadTitleRegeneration": true]],
      ],
    ])
    #expect(client.hasLoadedConfiguration)
    #expect(client.supportsTitleRegeneration)
    #expect(client.providers.first?["instanceId"] as? String == "pi")
    try client.applyConfigurationEvent([
      "version": 1, "type": "settingsUpdated",
      "payload": [
        "settings": ["providerModelPreferences": ["pi": ["hiddenModels": ["test/model"]]]]
      ],
    ])
    #expect(client.hiddenModelIDs == ["test/model"])
    client.applyProviderCatalog(
      [["instanceId": "pi", "models": [["slug": "test/new", "name": "Live"]]]],
      modelCatalogs: [
        "pi": [
          ["slug": "test/new", "name": "Stale"], ["slug": "test/model"], ["slug": "test/removed"],
        ]
      ])
    let models = try #require(client.providers.first?["models"] as? [[String: Any]])
    #expect(models.compactMap { $0["slug"] as? String } == ["test/new", "test/model"])
    #expect(models.first?["name"] as? String == "Live")
    #expect(throws: T3DesktopClient.ClientError.self) {
      try client.applyConfigurationEvent(["version": 1, "type": "snapshot", "config": [:]])
    }
    #expect(client.providers.first?["instanceId"] as? String == "pi")
    #expect(throws: T3DesktopClient.ClientError.self) {
      try client.applyConfigurationEvent(["version": 2, "type": "settingsUpdated", "payload": [:]])
    }
  }
}

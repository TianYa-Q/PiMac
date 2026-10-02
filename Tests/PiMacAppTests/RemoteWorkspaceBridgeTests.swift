import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct RemoteWorkspaceBridgeTests {
  @Test func mobileSendingRequiresSeparateConsentAndPersistsIt() throws {
    let suite = "PiMac.T3SendConsent.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let service = T3BridgeService(defaults: defaults)
    #expect(!service.allowsMessageSending)
    service.allowsMessageSending = true
    #expect(T3BridgeService(defaults: defaults).allowsMessageSending)
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let bridge = RemoteWorkspaceBridge(workspace: workspace)
    var code: String?
    bridge.handle(RemoteBridgeRequest(id: "disabled", method: "session.send", text: "hello")) {
      code = ($0["error"] as? [String: String])?["code"]
    }
    #expect(code == "sending_disabled")
  }

  @Test func snapshotIsJSONAndUsesExistingRuntimeIDs() throws {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let bridge = RemoteWorkspaceBridge(workspace: workspace)
    var response: [String: Any]?
    bridge.handle(RemoteBridgeRequest(id: "read", method: "workspace.snapshot")) { response = $0 }
    let value = try #require(response)
    #expect(JSONSerialization.isValidJSONObject(value))
    let result = try #require(value["result"] as? [String: Any])
    let sessions = try #require(result["sessions"] as? [[String: Any]])
    #expect(sessions.map { $0["id"] as? String } == workspace.tabs.map { $0.id.uuidString })
  }

  @Test func arbitraryPathsCannotBeUsedAsTargets() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let bridge = RemoteWorkspaceBridge(workspace: workspace)
    let selected = workspace.selectedTabID
    let count = workspace.tabs.count
    var code: String?
    bridge.handle(
      RemoteBridgeRequest(
        id: "attack", method: "session.prompt", target: "/tmp/session.jsonl", text: "hello")
    ) { code = ($0["error"] as? [String: String])?["code"] }
    #expect(code == "target_not_found")
    #expect(workspace.tabs.count == count)
    #expect(workspace.selectedTabID == selected)
  }

  @Test func rejectedPromptDoesNotConsumeDesktopDraft() throws {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let tab = try #require(workspace.tabs.first)
    tab.model.disconnect()
    tab.model.composerText = "keep this draft"
    let bridge = RemoteWorkspaceBridge(workspace: workspace)
    var code: String?
    bridge.handle(
      RemoteBridgeRequest(
        id: "write", method: "session.prompt", target: tab.id.uuidString, text: "remote")
    ) { code = ($0["error"] as? [String: String])?["code"] }
    #expect(code == "session_not_ready")
    #expect(tab.model.composerText == "keep this draft")
    #expect(workspace.selectedTabID == tab.id)
  }

  @Test func emptyPromptAndUnknownMethodFailClosed() throws {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let bridge = RemoteWorkspaceBridge(workspace: workspace)
    let tab = try #require(workspace.tabs.first)
    var codes: [String] = []
    for request in [
      RemoteBridgeRequest(
        id: "1", method: "session.prompt", target: tab.id.uuidString, text: " \n "),
      RemoteBridgeRequest(id: "2", method: "filesystem.write", target: tab.id.uuidString),
    ] {
      bridge.handle(request) {
        if let code = ($0["error"] as? [String: String])?["code"] { codes.append(code) }
      }
    }
    #expect(codes == ["invalid_request", "unsupported_method"])
  }

  @Test func bundledGatewayCanReadWorkspaceThroughRealPipes() async throws {
    let workspace = WorkspaceModel(restoreUserState: false)
    let unicodeText = "before\u{2028}middle\u{2029}after"
    let tab = try #require(workspace.tabs.first)
    tab.model.messages = [ChatEntry(id: "unicode", kind: .user, title: "You", text: unicodeText)]
    let service = T3BridgeService()
    defer {
      service.stop()
      workspace.disconnectAll()
    }
    let token = String(repeating: "ab", count: 32)
    let stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pimac-t3-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    try service.start(workspace: workspace, token: token, stateDirectory: stateDirectory)
    for _ in 0..<250 {
      if service.port != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let port = try #require(service.port)
    let url = try #require(URL(string: "http://127.0.0.1:\(port)/internal/request"))
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = Data(#"{"method":"workspace.snapshot"}"#.utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let result = try #require(object["result"] as? [String: Any])
    #expect(result["protocolVersion"] as? Int == 1)
    let sessions = try #require(result["sessions"] as? [[String: Any]])
    let messages = try #require(sessions.first?["messages"] as? [[String: Any]])
    #expect(messages.first?["text"] as? String == unicodeText)
    let discoveryURL = try #require(
      URL(string: "http://127.0.0.1:\(port)/.well-known/t3/environment"))
    let (discoveryData, discoveryResponse) = try await URLSession.shared.data(from: discoveryURL)
    #expect((discoveryResponse as? HTTPURLResponse)?.statusCode == 200)
    let descriptor = try #require(
      JSONSerialization.jsonObject(with: discoveryData) as? [String: Any])
    #expect(descriptor["label"] as? String == "Pi Mac")
    #expect(descriptor["orchestrationProtocolVersion"] as? Int == 1)
    #expect(
      FileManager.default.fileExists(
        atPath: stateDirectory.appendingPathComponent("auth.json").path))

    func call(
      _ path: String, method: String = "GET", bearer: String, body: Data? = nil,
      contentType: String = "application/json"
    ) async throws -> [String: Any] {
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
      request.httpMethod = method
      request.timeoutInterval = 5
      request.httpBody = body
      request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
      let (data, response) = try await URLSession.shared.data(for: request)
      #expect((response as? HTTPURLResponse)?.statusCode == 200)
      return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    // Startup alone is insufficient: GUI failures left HTTP alive after native
    // pipe delivery stopped. Exercise idle periods and multiple later replies.
    for _ in 0..<3 {
      try await Task.sleep(for: .milliseconds(100))
      let later = try await call(
        "/internal/request", method: "POST", bearer: token,
        body: Data(#"{"method":"workspace.snapshot"}"#.utf8))
      #expect((later["result"] as? [String: Any])?["protocolVersion"] as? Int == 1)
    }
    let pairing = try await call(
      "/internal/auth/pairing", method: "POST", bearer: token,
      body: Data("{}".utf8))
    let credential = try #require(pairing["credential"] as? String)
    var form = URLComponents()
    form.queryItems = [
      URLQueryItem(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:token-exchange"),
      URLQueryItem(name: "subject_token", value: credential),
      URLQueryItem(
        name: "subject_token_type", value: "urn:t3:params:oauth:token-type:environment-bootstrap"),
      URLQueryItem(
        name: "requested_token_type", value: "urn:ietf:params:oauth:token-type:access_token"),
    ]
    let exchange = try await call(
      "/oauth/token", method: "POST", bearer: token,
      body: Data((form.percentEncodedQuery ?? "").utf8),
      contentType: "application/x-www-form-urlencoded")
    let device = try #require(exchange["access_token"] as? String)
    let shell = try await call("/api/orchestration/shell", bearer: device)
    #expect(shell["projects"] is [[String: Any]])
    #expect(shell["threads"] is [[String: Any]])
    #expect(shell["snapshotSequence"] as? Int != nil)
    let ticket = try await call("/api/auth/websocket-ticket", method: "POST", bearer: device)
    let secret = try #require(ticket["ticket"] as? String)
    let socket = URLSession.shared.webSocketTask(
      with: URL(string: "ws://127.0.0.1:\(port)/ws?orchestrationProtocol=1&wsTicket=\(secret)")!)
    socket.resume()
    defer { socket.cancel(with: .normalClosure, reason: nil) }
    let cursor = try #require(shell["snapshotSequence"] as? Int)
    let payload: [String: Any] = [
      "_tag": "Request", "id": "read-shell", "tag": "orchestration.subscribeShell",
      "payload": ["afterSequence": cursor, "requestCompletionMarker": true], "headers": [],
    ]
    // Native URLSession binary JSON must work even after Effect switches ws to ArrayBuffer.
    try await socket.send(.data(try JSONSerialization.data(withJSONObject: payload)))
    var kinds: [String] = []
    for _ in 0..<2 {
      let frame = try await socket.receive()
      let frameData: Data
      switch frame {
      case .string(let text): frameData = Data(text.utf8)
      case .data(let data): frameData = data
      @unknown default: throw URLError(.badServerResponse)
      }
      let chunk = try #require(JSONSerialization.jsonObject(with: frameData) as? [String: Any])
      #expect(chunk["_tag"] as? String == "Chunk")
      let values = try #require(chunk["values"] as? [[String: Any]])
      kinds.append(contentsOf: values.compactMap { $0["kind"] as? String })
      if kinds.contains("synchronized") { break }
    }
    #expect(kinds == ["snapshot", "synchronized"])
    await service.refreshClients()
    #expect(service.clients.count == 1)
    let client = try #require(service.clients.first)
    #expect(client.connected)
    let diagnostics = try #require(service.readDiagnostics)
    #expect(diagnostics.shellHttpStatus == 200)
    #expect(diagnostics.catalogFailures == 0)
    #expect(diagnostics.shellSubscriptions == 1)
    #expect(diagnostics.shellSnapshots == 1)
    #expect(diagnostics.shellCompletionMarkers == 1)
    await service.generatePairing(label: "fixture iPhone")
    let nativePairing = try #require(service.pairing)
    #expect(nativePairing.credential.count == 64)
    #expect(nativePairing.expiry != nil)
    await service.discardPairing()
    #expect(service.pairing == nil)
    await service.revokeClient(client.id)
    #expect(service.clients.isEmpty)
    #expect(
      FileManager.default.fileExists(
        atPath: stateDirectory.appendingPathComponent("projection-clock.json").path))
  }

  @Test func pipeReadsSurviveFragmentationIdleAndChildReplacement() async throws {
    actor Records {
      var values: [Data] = []
      func append(_ value: Data) { values.append(value) }
    }
    let records = Records()
    let old = Pipe()
    let replacement = Pipe()
    T3BridgePipeReader.start(old.fileHandleForReading) { record in
      Task { await records.append(record) }
    }
    try old.fileHandleForWriting.write(contentsOf: Data("unfinished old record".utf8))
    try old.fileHandleForWriting.close()
    T3BridgePipeReader.start(replacement.fileHandleForReading) { record in
      Task { await records.append(record) }
    }
    try replacement.fileHandleForWriting.write(contentsOf: Data("{\"id\":\"".utf8))
    try await Task.sleep(for: .milliseconds(100))
    try replacement.fileHandleForWriting.write(contentsOf: Data("new\"}\n".utf8))
    // A large response spans several pipe reads; consume it while writing so it
    // cannot deadlock on the OS pipe buffer size.
    let large = Data((String(repeating: "x", count: 128 * 1024) + "\n").utf8)
    try replacement.fileHandleForWriting.write(contentsOf: large)
    try replacement.fileHandleForWriting.close()
    for _ in 0..<250 {
      if await records.values.count == 2 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let values = await records.values
    #expect(values.count == 2)
    #expect(values.contains(Data(#"{"id":"new"}"#.utf8)))
    #expect(values.contains(Data(large.dropLast())))
  }

  @Test func automaticRestoreRetainsConsentWhenSavedIPIsUnavailable() async throws {
    let suite = "pimac-t3-restore-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    let workspace = WorkspaceModel(restoreUserState: false)
    defer {
      workspace.disconnectAll()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let localHosts = Set(T3NetworkEndpoint.interfaces().map(\.address))
    let host = try #require(
      ["192.168.254.254", "10.254.254.254", "172.31.254.254"].first {
        !localHosts.contains($0)
      })
    let endpoint = try T3NetworkEndpoint(host: host, port: 3773)
    let first = T3BridgeService(defaults: defaults, stateDirectory: directory)
    defer { first.stop() }
    first.enable(workspace: workspace, network: endpoint)
    for _ in 0..<250 {
      if !first.isEnabled { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!first.isEnabled)
    #expect(first.publicURL == nil)
    #expect(T3ConnectionPreferences.load(from: defaults) == endpoint)
    first.stop()
    let restarted = T3BridgeService(defaults: defaults, stateDirectory: directory)
    defer { restarted.stop() }
    #expect(restarted.restoreRememberedConnection(workspace: workspace))
    for _ in 0..<250 {
      if !restarted.isEnabled { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!restarted.isEnabled)
    #expect(restarted.publicURL == nil)  // No fallback to another interface.
    #expect(restarted.rememberedNetwork == endpoint)
    #expect(T3ConnectionPreferences.load(from: defaults) == endpoint)
    restarted.disable()
    #expect(T3ConnectionPreferences.load(from: defaults) == nil)
  }

  @Test func stateDirectoryHasOneSupervisorOwner() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pimac-t3-lease-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try T3BridgeStateLease(directory: directory)
    #expect(throws: T3BridgeStateLease.LeaseError.self) {
      _ = try T3BridgeStateLease(directory: directory)
    }
    first.release()
    first.release()
    let second = try T3BridgeStateLease(directory: directory)
    second.release()
  }

  @Test func stateLockCannotBeASymlink() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pimac-t3-lease-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("other-file")
    try Data("unchanged".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("owner.lock"), withDestinationURL: target)
    #expect(throws: T3BridgeStateLease.LeaseError.self) {
      _ = try T3BridgeStateLease(directory: directory)
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "unchanged")
  }

  @Test func closingServiceIsIdempotent() {
    let service = T3BridgeService()
    service.stop()
    service.stop()
    #expect(service.port == nil)
    #expect(service.status == "未启用")
  }
}

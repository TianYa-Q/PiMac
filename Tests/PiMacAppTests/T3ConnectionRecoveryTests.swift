import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3ConnectionRecoveryTests {
  private final class Fixture: @unchecked Sendable {
    enum Reply {
      case json(Int, String)
      case failure(URLError.Code)
    }
    let url = URL(string: "http://\(UUID().uuidString.lowercased()).test")!
    private let lock = NSLock()
    private var replies: [Reply]
    private var captured: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func receive(_ request: URLRequest) -> Reply {
      lock.withLock {
        captured.append(request)
        return replies.isEmpty ? .failure(.badServerResponse) : replies.removeFirst()
      }
    }
    var requests: [URLRequest] { lock.withLock { captured } }
  }

  private final class ConnectionProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var fixtures: [String: Fixture] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      let fixture = Self.lock.withLock { Self.fixtures[request.url!.host!] }
      guard let fixture else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      switch fixture.receive(request) {
      case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
      case .json(let status, let body):
        let response = HTTPURLResponse(
          url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
      }
    }
    override func stopLoading() {}
  }

  private func withFixture(
    _ replies: [Fixture.Reply],
    run: (T3DesktopClient, Fixture) async throws -> Void
  ) async throws {
    let fixture = Fixture(replies)
    ConnectionProtocol.lock.withLock { ConnectionProtocol.fixtures[fixture.url.host!] = fixture }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ConnectionProtocol.self]
    let session = URLSession(configuration: configuration)
    let suite = "pimac-connection-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let client = T3DesktopClient(defaults: defaults, connectionSession: session)
    defer {
      client.stop()
      session.invalidateAndCancel()
      defaults.removePersistentDomain(forName: suite)
      _ = ConnectionProtocol.lock.withLock {
        ConnectionProtocol.fixtures.removeValue(forKey: fixture.url.host!)
      }
    }
    try await run(client, fixture)
  }

  @Test func refreshFailuresDoNotBlockSendingButRealDisconnectDoes() async throws {
    try await withFixture([
      .json(200, #"{"authenticated":true}"#), .failure(.timedOut),
      .json(200, #"{"authenticated":true}"#),
    ]) { client, fixture in
      var credentials = 0
      let credential = {
        credentials += 1
        return "fixture-token"
      }
      await client.refreshConnection(to: fixture.url, credential: credential)
      let model = AppModel(restoreLastProjectOnLaunch: false)
      defer { model.disconnect() }
      model.attach(to: client)
      model.connectionState = .connected
      model.composerText = "保留当前草稿"
      #expect(model.canSubmitPrompt)
      client.recordRefreshResult(.shell, error: URLError(.timedOut))
      client.recordRefreshResult(.configuration, error: T3DesktopClient.ClientError.rejected)
      #expect(client.isConnected)
      #expect(model.canSubmitPrompt)
      #expect(client.status.contains("会话列表刷新失败"))
      await client.refreshConnection(to: fixture.url, credential: credential)
      #expect(!client.isConnected)
      #expect(!model.canSubmitPrompt)
      #expect(client.status.contains("检查本机服务：请求超时"))
      #expect(model.composerText == "保留当前草稿")
      await client.refreshConnection(to: fixture.url, credential: credential)
      #expect(client.isConnected)
      #expect(model.canSubmitPrompt)
      #expect(model.composerText == "保留当前草稿")
      #expect(model.messages.isEmpty)
      #expect(credentials == 1)
      // 恢复连接不掩盖尚未恢复的读取，也不会把读取错误当作全局断线。
      client.recordRefreshResult(.shell, error: nil)
      #expect(client.status.contains("模型配置刷新失败"))
      client.recordRefreshResult(.configuration, error: nil)
      #expect(client.status == "T3 Server 已连接")
      #expect(fixture.requests.count == 3)
      #expect(fixture.requests.allSatisfy { $0.url?.path == "/api/auth/session" })
      #expect(fixture.requests.allSatisfy { $0.httpMethod == "GET" })
      #expect(fixture.requests.allSatisfy { $0.timeoutInterval == 3 })
    }
  }

  @Test func invalidCredentialsAreRenewedInsteadOfRetriedForever() async throws {
    try await withFixture([
      .json(401, "{}"), .json(200, #"{"authenticated":true}"#),
    ]) { client, fixture in
      var credentials = 0
      let credential = {
        credentials += 1
        return "fixture-\(credentials)"
      }
      await client.refreshConnection(to: fixture.url, credential: credential)
      #expect(!client.isConnected)
      #expect(client.status.contains("授权已失效"))
      await client.refreshConnection(to: fixture.url, credential: credential)
      #expect(client.isConnected)
      #expect(credentials == 2)
      #expect(
        fixture.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
          "Bearer fixture-1", "Bearer fixture-2",
        ])
    }
  }

  @Test(arguments: [#"{"authenticated":false}"#, "{}", "not-json"])
  func cachedShellAndUnverifiedResponsesCannotAuthorizeSending(body: String) async throws {
    try await withFixture([.json(200, body)]) { client, fixture in
      client.applyShell(["threads": [["id": "cached-thread"]]])
      await client.refreshConnection(to: fixture.url) { "fixture-token" }
      #expect(!client.isConnected)
      #expect(client.thread("cached-thread") != nil)
      #expect(client.status.contains("连接失败"))
    }
  }

  @Test func lateCredentialFailureCannotUndoNewerSuccessfulCheck() async throws {
    try await withFixture([.json(200, #"{"authenticated":true}"#)]) { client, fixture in
      var pending: CheckedContinuation<String, Error>?
      let old = Task {
        await client.refreshConnection(to: fixture.url) {
          try await withCheckedThrowingContinuation { pending = $0 }
        }
      }
      for _ in 0..<100 where pending == nil { await Task.yield() }
      let continuation = try #require(pending)
      await client.refreshConnection(to: fixture.url) { "new-token" }
      #expect(client.isConnected)
      continuation.resume(throwing: T3DesktopClient.ClientError.unauthorized)
      await old.value
      #expect(client.isConnected)
      #expect(client.status == "T3 Server 已连接")
      #expect(fixture.requests.count == 1)
    }
  }

  @Test func stoppedClientRejectsLateCredentialSuccess() async throws {
    try await withFixture([]) { client, fixture in
      var pending: CheckedContinuation<String, Error>?
      let old = Task {
        await client.refreshConnection(to: fixture.url) {
          try await withCheckedThrowingContinuation { pending = $0 }
        }
      }
      for _ in 0..<100 where pending == nil { await Task.yield() }
      let continuation = try #require(pending)
      client.stop()
      continuation.resume(returning: "stale-token")
      await old.value
      #expect(!client.isConnected)
      #expect(fixture.requests.isEmpty)
    }
  }
}

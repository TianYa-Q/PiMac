import Foundation

@MainActor
protocol T3RPCConnection: AnyObject {
  func send(_ text: String) async throws
  func receive() async throws -> Data
  func close()
}

@MainActor
final class T3WebSocketConnection: T3RPCConnection {
  private let socket: URLSessionWebSocketTask

  init(session: URLSession, url: URL) {
    socket = session.webSocketTask(with: url)
    socket.maximumMessageSize = 16 * 1024 * 1024
    socket.resume()
  }

  func send(_ text: String) async throws { try await socket.send(.string(text)) }

  func receive() async throws -> Data {
    switch try await socket.receive() {
    case .data(let data): return data
    case .string(let text): return Data(text.utf8)
    @unknown default: throw T3DesktopClient.ClientError.rejected
    }
  }

  func close() { socket.cancel(with: .goingAway, reason: nil) }
}

/// 一个环境复用一个官方 Effect RPC 连接；按 requestId 分发，不自动重放任何失败命令。
/// 超时/取消只 Interrupt 对应请求，不能像短连接那样断开其他命令和配置订阅。
@MainActor
final class T3RPCSession {
  typealias JSON = [String: Any]
  private struct Pending {
    let continuation: CheckedContinuation<JSON, Error>
    let receive: ((JSON) throws -> Void)?
    let stream: Bool
    var timeout: Task<Void, Never>?
    var sent = false
  }

  private let open: () async throws -> any T3RPCConnection
  private var connection: (any T3RPCConnection)?
  private var connecting: Task<Void, Never>?
  private var connectionWaiters: [String: CheckedContinuation<any T3RPCConnection, Error>] = [:]
  private var receiver: Task<Void, Never>?
  private var heartbeat: Task<Void, Never>?
  private var pending: [String: Pending] = [:]
  private var generation = UUID()
  private var awaitingPong: ContinuousClock.Instant?

  init(open: @escaping () async throws -> any T3RPCConnection) { self.open = open }

  func close(error: Error = CancellationError()) {
    SessionDiagnostics.record(
      "rpc.connection.close", id: generation.uuidString,
      fields: [
        "error": SessionDiagnostics.errorFields(error), "pending": Array(pending.keys),
        "waiters": Array(connectionWaiters.keys),
      ])
    generation = UUID()
    connecting?.cancel()
    connecting = nil
    receiver?.cancel()
    receiver = nil
    heartbeat?.cancel()
    heartbeat = nil
    connection?.close()
    connection = nil
    awaitingPong = nil
    let waiters = connectionWaiters
    connectionWaiters.removeAll()
    for waiter in waiters.values { waiter.resume(throwing: error) }
    let interrupted = pending
    pending.removeAll()
    for request in interrupted.values {
      request.timeout?.cancel()
      request.continuation.resume(throwing: error)
    }
  }

  private func connected() async throws -> any T3RPCConnection {
    try Task.checkCancellation()
    if let connection { return connection }
    let current = generation
    let id = UUID().uuidString
    // 所有并发首请求共用一次票据获取；等待者可独立取消，不必等共享建连结束。
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        connectionWaiters[id] = continuation
        guard connecting == nil else { return }
        connecting = Task { [weak self, open] in
          do {
            let socket = try await open()
            guard let self, !Task.isCancelled, current == self.generation else {
              socket.close()
              return
            }
            self.connection = socket
            self.connecting = nil
            self.startReceiving(socket, generation: current)
            let waiters = self.connectionWaiters
            self.connectionWaiters.removeAll()
            for waiter in waiters.values { waiter.resume(returning: socket) }
          } catch {
            if current == self?.generation { self?.close(error: error) }
          }
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.connectionWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
      }
    }
  }

  func call(
    _ method: String, payload: JSON = [:], timeout: Duration = .seconds(15),
    stream: Bool = false, receive: ((JSON) throws -> Void)? = nil
  ) async throws -> JSON {
    let socket = try await connected()
    let current = generation
    let id = UUID().uuidString
    let data = try await ImmutableJSONSnapshot(value: [
      "_tag": "Request", "id": id, "tag": method, "payload": payload, "headers": [],
    ]).encode()
    try Task.checkCancellation()
    guard current == generation else { throw CancellationError() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        let deadline = Task { [weak self] in
          do { try await Task.sleep(for: timeout) } catch { return }
          self?.finish(id, result: .failure(URLError(.timedOut)), interrupt: true)
        }
        pending[id] = Pending(
          continuation: continuation, receive: receive, stream: stream, timeout: deadline)
        Task { [weak self] in
          guard let self, current == self.generation, self.pending[id] != nil else { return }
          self.pending[id]?.sent = true
          SessionDiagnostics.record(
            "rpc.send", id: id,
            fields: [
              "connection": current.uuidString, "method": method,
              "timeout": String(describing: timeout),
              "frame": String(decoding: data, as: UTF8.self),
            ])
          do { try await socket.send(String(decoding: data, as: UTF8.self)) } catch {
            if current == self.generation { self.close(error: error) }
          }
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.finish(id, result: .failure(CancellationError()), interrupt: true)
      }
    }
  }

  private func finish(_ id: String, result: Result<JSON, Error>, interrupt: Bool = false) {
    guard let request = pending.removeValue(forKey: id) else { return }
    if case .failure(let error) = result {
      SessionDiagnostics.record(
        "rpc.failure", id: id,
        fields: [
          "connection": generation.uuidString, "sent": request.sent,
          "interrupt": interrupt, "error": SessionDiagnostics.errorFields(error),
        ])
    }
    request.timeout?.cancel()
    if interrupt, request.sent, let socket = connection {
      let current = generation
      Task { [weak self] in
        do {
          try await socket.send(#"{"_tag":"Interrupt","requestId":"\#(id)"}"#)
        } catch {
          if current == self?.generation { self?.close(error: error) }
        }
      }
    }
    request.continuation.resume(with: result)
  }

  private func startReceiving(_ socket: any T3RPCConnection, generation current: UUID) {
    receiver = Task { [weak self] in
      do {
        while !Task.isCancelled {
          let data = try await socket.receive()
          SessionDiagnostics.record(
            "rpc.receive", id: current.uuidString,
            fields: [
              "bytes": data.count, "frameBase64": data.base64EncodedString(),
              "frameUTF8": String(data: data, encoding: .utf8) ?? "",
            ])
          let frames = try await ImmutableJSONSnapshot.frames(data)
          guard let self, current == self.generation, !Task.isCancelled else { return }
          for frame in frames {
            guard current == self.generation else { return }
            try await self.accept(frame.value, socket: socket)
          }
        }
      } catch {
        if current == self?.generation { self?.close(error: error) }
      }
    }
    heartbeat = Task { [weak self] in
      do {
        while !Task.isCancelled {
          try await Task.sleep(for: .seconds(5))
          guard let self, current == self.generation else { return }
          if let sent = self.awaitingPong {
            if sent.duration(to: .now) >= .seconds(15) { throw URLError(.timedOut) }
          } else {
            self.awaitingPong = .now
            try await socket.send(#"{"_tag":"Ping"}"#)
          }
        }
      } catch {
        if !Task.isCancelled, current == self?.generation { self?.close(error: error) }
      }
    }
  }

  private func accept(_ frame: JSON, socket: any T3RPCConnection) async throws {
    switch frame["_tag"] as? String {
    case "Ping": try await socket.send(#"{"_tag":"Pong"}"#)
    case "Pong": awaitingPong = nil
    case "Chunk":
      guard let id = frame["requestId"] as? String, let values = frame["values"] as? [JSON],
        !values.isEmpty
      else {
        throw T3DesktopClient.ClientError.rejected
      }
      if let request = pending[id] {
        do {
          for value in values { try request.receive?(value) }
          // 官方订阅首块成功后转为常驻流；后续存活由同连接心跳负责。
          if request.stream {
            pending[id]?.timeout?.cancel()
            pending[id]?.timeout = nil
          }
        } catch {
          finish(id, result: .failure(error), interrupt: true)
        }
      }
      try await socket.send(#"{"_tag":"Ack","requestId":"\#(id)"}"#)
    case "Exit":
      guard let id = frame["requestId"] as? String, let exit = frame["exit"] as? JSON else {
        throw T3DesktopClient.ClientError.rejected
      }
      switch exit["_tag"] as? String {
      case "Success": finish(id, result: .success(exit["value"] as? JSON ?? [:]))
      case "Failure": finish(id, result: .failure(T3DesktopClient.RPCFailure(exit: exit)))
      default: throw T3DesktopClient.ClientError.rejected
      }
    default: throw T3DesktopClient.ClientError.rejected
    }
  }
}

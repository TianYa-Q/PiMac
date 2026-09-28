import Foundation

/// Serializes the RPC handoff. `abort` acknowledges only once Pi is idle; queued work
/// must be removed first, otherwise Pi may start it before the account is switched.
@MainActor
final class CodexAccountHandoff {
  typealias Reply = Result<PiRPCClient.JSON, Error>
  typealias Request = (PiRPCClient.JSON, @escaping (Reply) -> Void) -> Void

  private var operation: UUID?
  private var cancelled = false

  func cancel() { cancelled = true }
  func reset() { operation = nil }

  func start(
    target: String, interrupt: Bool, request: @escaping Request,
    preserveQueue: @escaping (PiRPCClient.JSON) -> Void,
    verifyAccount: @escaping () -> Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let id = UUID()
    operation = id
    cancelled = false

    func finish(_ result: Result<Void, Error>) {
      guard self.operation == id else { return }
      self.operation = nil
      completion(result)
    }

    func switchAccount() {
      guard self.operation == id else { return }
      guard !self.cancelled else {
        finish(.failure(CancellationError()))
        return
      }
      request(["type": "prompt", "message": "/accounts switch \(target)"]) { result in
        guard self.operation == id else { return }
        if self.cancelled {
          finish(.failure(CancellationError()))
          return
        }
        switch result {
        case .failure(let error): finish(.failure(error))
        case .success:
          guard verifyAccount() else {
            finish(.failure(HandoffError.unconfirmedAccount))
            return
          }
          finish(.success(()))
        }
      }
    }

    guard interrupt else {
      switchAccount()
      return
    }
    request(["type": "clear_queue"]) { result in
      guard self.operation == id else { return }
      switch result {
      case .failure(let error): finish(.failure(error))
      case .success(let response):
        guard let data = response["data"] as? PiRPCClient.JSON,
          data["steering"] is [String], data["followUp"] is [String]
        else {
          finish(.failure(HandoffError.invalidQueue))
          return
        }
        preserveQueue(data)
        // Even after manual cancellation, finish stopping the interrupted operation.
        request(["type": "abort"]) { result in
          guard self.operation == id else { return }
          switch result {
          case .failure(let error): finish(.failure(error))
          case .success: switchAccount()
          }
        }
      }
    }
  }

  private enum HandoffError: LocalizedError {
    case invalidQueue, unconfirmedAccount
    var errorDescription: String? {
      switch self {
      case .invalidQueue: return "无法保存等待队列，已取消自动切换"
      case .unconfirmedAccount: return "未确认目标账户已生效，未自动继续任务"
      }
    }
  }
}

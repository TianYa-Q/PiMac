import Foundation

/// Transport errors deliberately contain no URL or server-supplied description (bot secrets).
enum TelegramAPIError: Error, Equatable {
  case failed, notModified, cardUnavailable
  case permanent(Int)
  case rateLimited(Double)

  var retryable: Bool {
    switch self {
    case .failed, .rateLimited: return true
    default: return false
    }
  }
}

@MainActor
enum TelegramAPI {
  struct SentMessage: Decodable {
    let messageID: Int64
    enum CodingKeys: String, CodingKey { case messageID = "message_id" }
  }
  struct Envelope<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
  }
  private struct Failure: Decodable {
    let description: String?
    let parameters: Parameters?
    struct Parameters: Decodable {
      let retryAfter: Double?
      enum CodingKeys: String, CodingKey { case retryAfter = "retry_after" }
    }
  }

  static func classify(status: Int, data: Data, method: String) -> TelegramAPIError {
    let failure = try? JSONDecoder().decode(Failure.self, from: data)
    if status == 429 {
      let delay = failure?.parameters?.retryAfter ?? 5
      return .rateLimited(delay.isFinite ? max(1, delay) : 5)
    }
    if status == 400, method == "editMessageText" {
      let description = failure?.description ?? ""
      if description.contains("message is not modified") { return .notModified }
      if description.contains("message to edit not found")
        || description.contains("message can't be edited")
      {
        return .cardUnavailable
      }
    }
    return (400..<500).contains(status) ? .permanent(status) : .failed
  }

  static func decode<T: Decodable>(
    _ type: T.Type, data: Data, response: URLResponse, method: String
  ) throws -> T {
    guard let status = (response as? HTTPURLResponse)?.statusCode else {
      throw TelegramAPIError.failed
    }
    guard status == 200 else { throw classify(status: status, data: data, method: method) }
    guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data),
      envelope.ok, let result = envelope.result
    else { throw TelegramAPIError.failed }
    return result
  }

  static func call<T: Decodable>(token: String, method: String, body: [String: Any]) async throws
    -> T
  {
    guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
      throw TelegramAPIError.permanent(401)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 35
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    return try decode(T.self, data: data, response: response, method: method)
  }
}

/// Shared retry policy for polling and the persisted outbox.
struct TelegramRetryPolicy {
  private(set) var failures = 0
  mutating func reset() { failures = 0 }
  mutating func delay(for error: Error) -> Double? {
    if error is CancellationError { return nil }
    if let api = error as? TelegramAPIError, !api.retryable { return nil }
    failures = min(failures + 1, 7)
    let backoff = min(300, 5 * pow(2, Double(failures - 1)))
    if case .rateLimited(let seconds) = error as? TelegramAPIError {
      return max(backoff, seconds)
    }
    return backoff
  }
  static let pausedMessage =
    "Telegram 连接或发送已暂停，请检查 Token、用户 ID、Bot 权限或 Webhook；修正配置后点击「重新连接」。待发送结果仍保留。"
}

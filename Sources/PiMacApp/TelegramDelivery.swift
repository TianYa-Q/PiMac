import Foundation

/// Message rendering and delivery, independent of session/task scheduling.
@MainActor
enum TelegramDelivery {
  static func chunks(_ text: String, limit: Int = 3500) -> [String] {
    let limit = max(2, limit)
    var result: [String] = []
    var chunk = ""
    var count = 0
    for scalar in text.unicodeScalars {
      let size = scalar.value > 0xFFFF ? 2 : 1
      if count + size > limit {
        result.append(chunk)
        chunk = ""
        count = 0
      }
      chunk.unicodeScalars.append(scalar)
      count += size
    }
    if !chunk.isEmpty { result.append(chunk) }
    return result
  }

  @discardableResult
  static func send(
    _ text: String, token: String, userID: Int64,
    keyboard: [[[String: String]]]? = nil, startingAt: Int = 0,
    allowed: () -> Bool = { true }, onSent: ((Int64) -> Void)? = nil
  ) async throws -> Int64? {
    try await sendPieces(
      text, keyboard: keyboard, startingAt: startingAt, allowed: allowed,
      onSent: onSent
    ) { body in
      var body = body
      body["chat_id"] = userID
      let sent: TelegramAPI.SentMessage = try await TelegramAPI.call(
        token: token, method: "sendMessage", body: body)
      return sent.messageID
    }
  }

  /// Injectable transport makes partial delivery and cancellation testable without Telegram.
  @discardableResult
  static func sendPieces(
    _ text: String, keyboard: [[[String: String]]]? = nil, startingAt: Int = 0,
    allowed: () -> Bool = { true }, onSent: ((Int64) -> Void)? = nil,
    transmit: ([String: Any]) async throws -> Int64
  ) async throws -> Int64? {
    let pieces = chunks(text.isEmpty ? "（空回复）" : text)
    var lastID: Int64?
    for index in pieces.indices where index >= max(0, startingAt) {
      try Task.checkCancellation()
      guard allowed() else { throw CancellationError() }
      var body: [String: Any] = [
        "text": TelegramMarkdown.html(pieces[index]), "parse_mode": "HTML",
      ]
      if index == pieces.count - 1, let keyboard {
        body["reply_markup"] = ["inline_keyboard": keyboard]
      }
      let id = try await transmit(body)
      lastID = id
      onSent?(id)
    }
    return lastID
  }

  static func editOrSend(
    _ text: String, token: String, userID: Int64, messageID: Int64?,
    keyboard: [[[String: String]]]? = nil
  ) async throws -> Int64? {
    try await editPieces(
      text, userID: userID, messageID: messageID, keyboard: keyboard,
      edit: { body in
        let _: TelegramAPI.SentMessage = try await TelegramAPI.call(
          token: token, method: "editMessageText", body: body)
      },
      send: { startingAt in
        try await send(
          text, token: token, userID: userID, keyboard: keyboard, startingAt: startingAt)
      })
  }

  static func editPieces(
    _ text: String, userID: Int64, messageID: Int64?, keyboard: [[[String: String]]]? = nil,
    edit: ([String: Any]) async throws -> Void, send: (Int) async throws -> Int64?
  ) async throws -> Int64? {
    guard let messageID else { return try await send(0) }
    let pieces = chunks(text.isEmpty ? "（空回复）" : text)
    let body: [String: Any] = [
      "chat_id": userID, "message_id": messageID,
      "text": TelegramMarkdown.html(pieces[0]), "parse_mode": "HTML",
      "reply_markup": ["inline_keyboard": pieces.count == 1 ? (keyboard ?? []) : []],
    ]
    do {
      try await edit(body)
    } catch TelegramAPIError.notModified {
      // Already current.
    } catch TelegramAPIError.cardUnavailable {
      return try await send(0)
    }
    guard pieces.count > 1 else { return messageID }
    return try await send(1) ?? messageID
  }
}

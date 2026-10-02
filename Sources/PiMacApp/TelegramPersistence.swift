import Foundation

/// The offset is checkpointed before dispatching an update. This favors at-most-once
/// execution of remote commands over replaying a command after a crash.
enum TelegramUpdateCursorStore {
  private static let key = "telegram.updateOffset"

  static func load(defaults: UserDefaults = .standard) -> Int64? {
    guard let number = defaults.object(forKey: key) as? NSNumber, number.int64Value >= 0
    else { return nil }
    return number.int64Value
  }

  static func save(_ offset: Int64, defaults: UserDefaults = .standard) {
    defaults.set(offset, forKey: key)
  }

  static func clear(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: key)
  }

  static func earliestMessageDate(now: Date, defaults: UserDefaults = .standard) -> Date {
    load(defaults: defaults) == nil ? now : .distantPast
  }
}

struct TelegramUnsentReply: Codable, Equatable {
  let id: UUID
  let sessionPath: String
  let text: String
  // Optional for backwards-compatible decoding of older persisted replies.
  var deliveredChunks: Int? = nil
}

enum TelegramUnsentReplyStore {
  private static let key = "telegram.unsentReplies"

  static func load(defaults: UserDefaults = .standard) -> [String: [TelegramUnsentReply]] {
    guard let data = defaults.data(forKey: key) else { return [:] }
    if let replies = try? JSONDecoder().decode([String: [TelegramUnsentReply]].self, from: data) {
      return replies
    }
    // Migrate the previous single-reply-per-project format.
    let old = (try? JSONDecoder().decode([String: TelegramUnsentReply].self, from: data)) ?? [:]
    return old.mapValues { [$0] }
  }

  static func save(_ replies: [String: [TelegramUnsentReply]], defaults: UserDefaults = .standard) {
    TelegramStoredJSON.save(replies, key: key, isEmpty: replies.isEmpty, defaults: defaults)
  }
}

struct TelegramPendingNotice: Codable, Equatable {
  let id: UUID
  let text: String
  let keyboard: [[[String: String]]]?
  let sourceMessageID: Int64?
  var editMessageID: Int64? = nil
  var cardRevision: UUID? = nil
  var deliveredChunks: Int? = nil

  init(
    id: UUID, text: String, keyboard: [[[String: String]]]?, sourceMessageID: Int64? = nil,
    editMessageID: Int64? = nil, deliveredChunks: Int? = nil, cardRevision: UUID? = nil
  ) {
    self.id = id
    self.text = text
    self.keyboard = keyboard
    self.sourceMessageID = sourceMessageID
    self.editMessageID = editMessageID
    self.cardRevision = cardRevision
    self.deliveredChunks = deliveredChunks
  }
}

enum TelegramPendingNoticeStore {
  private static let key = "telegram.pendingNotices"

  static func load(defaults: UserDefaults = .standard) -> [TelegramPendingNotice] {
    TelegramStoredJSON.load(
      [TelegramPendingNotice].self, key: key, fallback: [], defaults: defaults)
  }

  static func save(_ notices: [TelegramPendingNotice], defaults: UserDefaults = .standard) {
    TelegramStoredJSON.save(notices, key: key, isEmpty: notices.isEmpty, defaults: defaults)
  }
}

struct TelegramPendingFile: Codable, Equatable {
  let id: UUID
  let projectPath: String
  let filePath: String
}

enum TelegramPendingFileStore {
  private static let key = "telegram.pendingFiles"

  static func load(defaults: UserDefaults = .standard) -> [TelegramPendingFile] {
    TelegramStoredJSON.load([TelegramPendingFile].self, key: key, fallback: [], defaults: defaults)
  }

  static func save(_ files: [TelegramPendingFile], defaults: UserDefaults = .standard) {
    TelegramStoredJSON.save(files, key: key, isEmpty: files.isEmpty, defaults: defaults)
  }
}

private enum TelegramStoredJSON {
  static func load<Value: Decodable>(
    _ type: Value.Type, key: String, fallback: Value, defaults: UserDefaults
  ) -> Value {
    guard let data = defaults.data(forKey: key) else { return fallback }
    return (try? JSONDecoder().decode(type, from: data)) ?? fallback
  }

  static func save<Value: Encodable>(
    _ value: Value, key: String, isEmpty: Bool, defaults: UserDefaults
  ) {
    if isEmpty {
      defaults.removeObject(forKey: key)
    } else if let data = try? JSONEncoder().encode(value) {
      defaults.set(data, forKey: key)
    }
  }
}

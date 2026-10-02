import CryptoKit
// Read-only parsers retained for explicit historical import. Not a live backend.
import Foundation
import UniformTypeIdentifiers

extension AppModel {
  nonisolated static func sessionSearchRoot(for projectPath: String, root: URL) -> URL {
    let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    guard root.standardizedFileURL == defaultRoot.standardizedFileURL else { return root }
    let path = URL(fileURLWithPath: projectPath).standardizedFileURL.path
    let name =
      "--"
      + path.dropFirst().replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-") + "--"
    return root.appendingPathComponent(name, isDirectory: true)
  }

  nonisolated static func discoverSessions(
    for projectPath: String,
    root: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
  ) -> [SessionItem] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: sessionSearchRoot(for: projectPath, root: root),
        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    var result: [SessionItem] = []
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      let item = SessionDiscoveryCache.shared.item(at: url, project: projectPath) {
        guard let preview = sessionPreview(inFile: url, projectPath: projectPath) else {
          return nil
        }
        let header = preview.header
        var title = (header["name"] as? String) ?? (header["sessionName"] as? String) ?? ""
        if title.isEmpty { title = preview.text }
        if title.isEmpty { title = "未命名会话" }
        // Only user messages affect ordering, not tool output or opening a session.
        return SessionItem(
          path: url.path, title: String(title.prefix(70)),
          modifiedAt: latestUserMessageDate(inFile: url) ?? recordDate(header) ?? .distantPast)
      }
      if let item { result.append(item) }
    }
    return result.sorted { $0.modifiedAt > $1.modifiedAt }
  }

  nonisolated static func sessionExists(
    at path: String, for projectPath: String,
    root: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
  ) -> Bool {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard url.path.hasPrefix(root.standardizedFileURL.path + "/"),
      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    else { return false }
    return sessionPreview(inFile: url, projectPath: projectPath) != nil
  }

  /// Read complete JSONL records: image attachments and UTF-8 characters can cross chunk boundaries.
  /// Stop after the first user message; header-only drafts stay hidden.
  nonisolated private static func sessionPreview(
    inFile url: URL, projectPath: String
  ) -> (header: PiRPCClient.JSON, text: String)? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var header: PiRPCClient.JSON?
    var pending = Data()
    while true {
      let chunk: Data
      do {
        chunk = try handle.read(upToCount: 262_144) ?? Data()
      } catch {
        return nil
      }
      let atEnd = chunk.isEmpty
      var start = chunk.startIndex
      while start < chunk.endIndex || (atEnd && !pending.isEmpty) {
        let newline = chunk[start...].firstIndex(of: 0x0A)
        let end = newline ?? chunk.endIndex
        pending.append(contentsOf: chunk[start..<end])
        start = newline.map { $0 + 1 } ?? chunk.endIndex
        if newline == nil && !atEnd { break }
        let line = pending
        pending = Data()
        if line.isEmpty { continue }
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? PiRPCClient.JSON
        else {
          if header == nil { return nil }
          continue
        }
        if header == nil {
          guard entry["type"] as? String == "session",
            (entry["cwd"] as? String).map({ URL(fileURLWithPath: $0).standardizedFileURL.path })
              == projectPath
          else { return nil }
          header = entry
        } else if entry["type"] as? String == "message",
          let message = entry["message"] as? PiRPCClient.JSON,
          message["role"] as? String == "user", let header
        {
          return (
            header,
            contentText(message["content"])
              .trimmingCharacters(in: .whitespacesAndNewlines)
              .replacingOccurrences(of: "\n", with: " ")
          )
        }
      }
      if atEnd { break }
    }
    return nil
  }

  nonisolated static func mostRecentConversationSession(
    for projectPath: String, since cutoff: Date, now: Date,
    archivedPaths: Set<String> = [],
    root: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
  ) -> String? {
    guard
      let enumerator = FileManager.default.enumerator(
        at: sessionSearchRoot(for: projectPath, root: root),
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles])
    else { return nil }
    var newest: (path: String, date: Date)?
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      guard !archivedPaths.contains(url.path),
        let values = try? url.resourceValues(forKeys: [
          .contentModificationDateKey, .isRegularFileKey,
        ]),
        values.isRegularFile == true,
        let modified = values.contentModificationDate, modified >= cutoff,
        sessionPreview(inFile: url, projectPath: projectPath) != nil,
        let date = latestMessageDate(inFile: url, includeAssistant: true),
        date >= cutoff, date <= now
      else { continue }
      if newest == nil || date > newest!.date { newest = (url.path, date) }
    }
    return newest?.path
  }

  nonisolated private static func latestMessageDate(
    in lines: [Substring], includeAssistant: Bool
  ) -> Date? {
    for line in lines.reversed() {
      guard let data = String(line).data(using: .utf8),
        let record = try? JSONSerialization.jsonObject(with: data) as? PiRPCClient.JSON,
        record["type"] as? String == "message",
        let message = record["message"] as? PiRPCClient.JSON,
        let role = message["role"] as? String,
        role == "user"
          || (includeAssistant && role == "assistant"
            && !contentText(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
              .isEmpty)
      else { continue }
      if let date = recordDate(record) { return date }
    }
    return nil
  }

  /// 从文件尾部反向分块查找，避免为确定会话顺序而把可能很大的 JSONL 全部载入内存。
  /// 跨分块的超长消息行会保留到下一轮，因此最后一条用户消息不会因大段工具输出而遗漏。
  nonisolated static func latestUserMessageDate(inFile url: URL) -> Date? {
    latestMessageDate(inFile: url, includeAssistant: false)
  }

  nonisolated static func latestConversationMessageDate(inFile url: URL) -> Date? {
    latestMessageDate(inFile: url, includeAssistant: true)
  }

  nonisolated private static func latestMessageDate(inFile url: URL, includeAssistant: Bool)
    -> Date?
  {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }

    // Most sessions have a recent user message near the tail. Avoid decoding a full
    // megabyte (often containing tool output) just to find its timestamp.
    let chunkSize: UInt64 = 65_536
    var end = size
    var suffix = Data()
    while end > 0 {
      let start = end > chunkSize ? end - chunkSize : 0
      try? handle.seek(toOffset: start)
      guard let chunk = try? handle.read(upToCount: Int(end - start)) else { return nil }
      var combined = chunk
      combined.append(suffix)

      if start == 0 {
        let text = String(decoding: combined, as: UTF8.self)
        return latestMessageDate(
          in: text.split(separator: "\n", omittingEmptySubsequences: true),
          includeAssistant: includeAssistant)
      }

      guard let firstNewline = combined.firstIndex(of: 0x0A) else {
        suffix = combined
        end = start
        continue
      }
      let completeLines = combined[combined.index(after: firstNewline)...]
      let text = String(decoding: completeLines, as: UTF8.self)
      if let date = latestMessageDate(
        in: text.split(separator: "\n", omittingEmptySubsequences: true),
        includeAssistant: includeAssistant)
      {
        return date
      }
      suffix = Data(combined[..<firstNewline])
      end = start
    }
    return nil
  }

  nonisolated private static func recordDate(_ record: PiRPCClient.JSON) -> Date? {
    if let timestamp = record["timestamp"] as? String {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: timestamp) { return date }
      formatter.formatOptions = [.withInternetDateTime]
      if let date = formatter.date(from: timestamp) { return date }
    }
    if let message = record["message"] as? PiRPCClient.JSON,
      let milliseconds = message["timestamp"] as? NSNumber
    {
      return Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
    }
    return nil
  }

  /// RPC 事件种类较多，这里只把会影响原生界面的状态集中映射，避免视图层理解协议细节。

  nonisolated static func loadTranscript(at path: String) -> [ChatEntry] {
    guard let data = FileManager.default.contents(atPath: path),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    let records = text.split(separator: "\n").compactMap { line -> PiRPCClient.JSON? in
      guard let data = String(line).data(using: .utf8) else { return nil }
      return try? JSONSerialization.jsonObject(with: data) as? PiRPCClient.JSON
    }

    // Pi sessions are trees after edits/branching. Follow the latest leaf back to the root so
    // abandoned branches are not mixed into the visible transcript. Legacy files have no IDs.
    let indexed = Dictionary(
      uniqueKeysWithValues: records.compactMap { record -> (String, PiRPCClient.JSON)? in
        guard let id = record["id"] as? String else { return nil }
        return (id, record)
      }
    )
    let branchRecords: [PiRPCClient.JSON]
    if let leafID = records.last?["id"] as? String, !indexed.isEmpty {
      var branchIDs = Set<String>()
      var currentID: String? = leafID
      while let id = currentID, let record = indexed[id], branchIDs.insert(id).inserted {
        currentID = record["parentId"] as? String
      }
      branchRecords = records.filter { record in
        guard let id = record["id"] as? String else { return false }
        return branchIDs.contains(id)
      }
    } else {
      branchRecords = records
    }

    var entries: [ChatEntry] = []
    var messageBuffer: [PiRPCClient.JSON] = []
    var currentProvider: String?
    var currentModelID: String?

    func flushMessages() {
      entries.append(contentsOf: chatEntries(from: messageBuffer))
      messageBuffer.removeAll()
    }

    for record in branchRecords {
      switch record["type"] as? String {
      case "model_change":
        currentProvider = record["provider"] as? String
        currentModelID = record["modelId"] as? String
      case "message":
        guard var message = record["message"] as? PiRPCClient.JSON else { continue }
        if message["role"] as? String == "assistant" {
          message["provider"] = message["provider"] ?? currentProvider
          message["model"] = message["model"] ?? currentModelID
        }
        if message["timestamp"] == nil { message["timestamp"] = record["timestamp"] }
        messageBuffer.append(message)
      case "compaction":
        flushMessages()
        let details = record["details"] as? PiRPCClient.JSON
        entries.append(
          ChatEntry(
            id: record["id"] as? String ?? UUID().uuidString,
            kind: .compaction,
            title: "上下文压缩",
            text: record["summary"] as? String ?? "压缩完成",
            modelProvider: details?["compactionProvider"] as? String ?? currentProvider,
            modelID: details?["compactionModelId"] as? String ?? currentModelID,
            timestamp: recordDate(record)
          ))
      default:
        continue
      }
    }
    flushMessages()
    return entries
  }

  nonisolated static func chatEntries(
    from messages: [PiRPCClient.JSON]
  ) -> [ChatEntry] {
    var toolInputs: [String: String] = [:]
    var entries: [ChatEntry] = []
    // One reverse pass avoids scanning the rest of the transcript for every failed retry.
    var retriedBeforeNextUser = Array(repeating: false, count: messages.count)
    var laterAssistant = false
    for index in messages.indices.reversed() {
      retriedBeforeNextUser[index] = laterAssistant
      switch messages[index]["role"] as? String {
      case "user": laterAssistant = false
      case "assistant": laterAssistant = true
      default: break
      }
    }

    for (messageIndex, message) in messages.enumerated() {
      let hidesRetriedError = isAssistantError(message) && retriedBeforeNextUser[messageIndex]

      if message["role"] as? String == "assistant",
        let blocks = message["content"] as? [PiRPCClient.JSON]
      {
        for block in blocks where block["type"] as? String == "toolCall" {
          guard let id = block["id"] as? String,
            let name = block["name"] as? String,
            let input = toolInputText(toolName: name, args: block["arguments"])
          else { continue }
          toolInputs[id] = input
        }
      }

      if message["role"] as? String == "assistant",
        let blocks = message["content"] as? [PiRPCClient.JSON],
        blocks.contains(where: { $0["type"] as? String == "thinking" })
      {
        let provider = message["provider"] as? String
        let modelID = message["model"] as? String
        var currentKind: ChatEntryKind?
        var currentText = ""
        func flushBlock() {
          guard let kind = currentKind, !currentText.isEmpty else { return }
          entries.append(
            ChatEntry(
              id: UUID().uuidString, kind: kind,
              title: kind == .thinking ? "思考过程" : "Pi", text: currentText,
              modelProvider: provider, modelID: modelID,
              timestamp: messageDate(message)
            ))
        }
        for block in blocks {
          let kind: ChatEntryKind
          let text: String
          switch block["type"] as? String {
          case "thinking":
            kind = .thinking
            text = block["thinking"] as? String ?? ""
          case "text":
            kind = .assistant
            text = block["text"] as? String ?? ""
          default:
            flushBlock()
            currentKind = nil
            currentText = ""
            continue
          }
          if kind != currentKind {
            flushBlock()
            currentKind = kind
            currentText = ""
          }
          if !text.isEmpty {
            if !currentText.isEmpty { currentText += "\n" }
            currentText += text
          }
        }
        flushBlock()
        if !hidesRetriedError, let errorText = assistantErrorText(message) {
          entries.append(
            ChatEntry(
              id: UUID().uuidString, kind: .system, title: "错误",
              text: errorText, isError: true, timestamp: messageDate(message)
            ))
        }
        continue
      }

      guard var entry = chatEntry(from: message) else { continue }
      if hidesRetriedError, entry.kind == .system, entry.isError { continue }
      if entry.kind == .tool, entry.toolInput == nil {
        entry.toolInput = toolInputs[entry.id]
      }
      entries.append(entry)
      if !hidesRetriedError, message["role"] as? String == "assistant",
        entry.kind == .assistant, let errorText = assistantErrorText(message)
      {
        entries.append(
          ChatEntry(
            id: UUID().uuidString,
            kind: .system,
            title: "错误",
            text: errorText,
            isError: true,
            timestamp: messageDate(message)
          ))
      }
    }
    return entries
  }

  nonisolated private static func messageDate(_ message: PiRPCClient.JSON) -> Date? {
    recordDate(["message": message]) ?? recordDate(message)
  }

  nonisolated static func chatEntry(from message: PiRPCClient.JSON) -> ChatEntry? {
    guard let role = message["role"] as? String else { return nil }
    switch role {
    case "user":
      let content = message["content"]
      let parsed = parseUserContent(contentText(content))
      return ChatEntry(
        id: UUID().uuidString,
        kind: .user,
        title: "你",
        text: parsed.text,
        attachments: parsed.attachments + restoreImageAttachments(from: content),
        timestamp: messageDate(message)
      )
    case "assistant":
      let text = contentText(message["content"])
      if !text.isEmpty {
        return ChatEntry(
          id: UUID().uuidString,
          kind: .assistant,
          title: "Pi",
          text: text,
          modelProvider: message["provider"] as? String,
          modelID: message["model"] as? String,
          timestamp: messageDate(message)
        )
      }
      if let errorText = assistantErrorText(message) {
        return ChatEntry(
          id: UUID().uuidString,
          kind: .system,
          title: "错误",
          text: errorText,
          isError: true,
          timestamp: messageDate(message)
        )
      }
      return nil
    case "toolResult":
      return ChatEntry(
        id: message["toolCallId"] as? String ?? UUID().uuidString,
        kind: .tool,
        title: "工具 · \(message["toolName"] as? String ?? "tool")",
        text: resultText(
          message,
          toolName: message["toolName"] as? String,
          preferCompleteOutput: true
        ),
        isError: message["isError"] as? Bool ?? false,
        toolName: message["toolName"] as? String,
        nestedCalls: NestedToolCall.from(message["nestedCalls"]),
        nestedCallsComplete: (message["nestedCalls"] as? PiRPCClient.JSON)?["complete"] as? Bool
          ?? true,
        diff: (message["details"] as? PiRPCClient.JSON)?["diff"] as? String
          ?? (message["details"] as? PiRPCClient.JSON)?["patch"] as? String,
        attachments: restoreImageAttachments(from: message["content"]),
        timestamp: messageDate(message)
      )
    case "bashExecution":
      return ChatEntry(
        id: UUID().uuidString,
        kind: .tool,
        title: "命令",
        text: message["output"] as? String ?? "",
        toolName: "bash",
        toolInput: (message["command"] as? String).map { "$ \($0)" },
        timestamp: messageDate(message)
      )
    default:
      return nil
    }
  }

  nonisolated private static func isAssistantError(_ message: PiRPCClient.JSON) -> Bool {
    message["role"] as? String == "assistant" && message["stopReason"] as? String == "error"
  }

  nonisolated private static func assistantErrorText(
    _ message: PiRPCClient.JSON
  ) -> String? {
    guard message["stopReason"] as? String == "error" else { return nil }
    let detail = (message["errorMessage"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return detail?.isEmpty == false ? detail : "模型调用失败，未生成回复。"
  }

  nonisolated private static func parseUserContent(
    _ content: String
  ) -> (text: String, attachments: [PromptAttachment]) {
    let startMarker = "<pi-mac-attached-files>"
    let endMarker = "</pi-mac-attached-files>"
    guard let start = content.range(of: startMarker),
      let end = content.range(of: endMarker, range: start.upperBound..<content.endIndex)
    else { return (content, []) }

    let paths = content[start.upperBound..<end.lowerBound]
      .split(separator: "\n")
      .map(String.init)
    let attachments = paths.map { path in
      PromptAttachment(
        url: URL(fileURLWithPath: path),
        mimeType: UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?
          .preferredMIMEType
      )
    }
    var displayText = content
    displayText.removeSubrange(start.lowerBound..<end.upperBound)
    return (displayText.trimmingCharacters(in: .whitespacesAndNewlines), attachments)
  }

  nonisolated static func contentText(_ content: Any?) -> String {
    if let text = content as? String { return text }
    guard let blocks = content as? [PiRPCClient.JSON] else { return "" }
    return blocks.compactMap { block in
      switch block["type"] as? String {
      case "text": return block["text"] as? String
      case "thinking": return nil
      default: return nil
      }
    }.joined(separator: "\n")
  }

  /// Pi 会把用户图片以 Base64 内容块保存在会话 JSONL 中。恢复会话时将内容块
  /// 落盘到稳定目录；以内容摘要命名可以让多次刷新复用同一个文件。
  nonisolated private static func restoreImageAttachments(from content: Any?) -> [PromptAttachment]
  {
    guard let blocks = content as? [PiRPCClient.JSON] else { return [] }
    let fileManager = FileManager.default
    guard
      let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { return [] }
    let directory = applicationSupport.appendingPathComponent(
      "PiMac/Attachments", isDirectory: true)

    return blocks.compactMap { block in
      guard block["type"] as? String == "image",
        let mimeType = block["mimeType"] as? String,
        mimeType.hasPrefix("image/"),
        let encoded = block["data"] as? String,
        encoded.utf8.count <= 28 * 1_024 * 1_024,
        let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
        data.count <= 20 * 1_024 * 1_024
      else { return nil }

      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      let fileExtension = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "img"
      let url = directory.appendingPathComponent("pi-session-\(digest).\(fileExtension)")
      do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
          try data.write(to: url, options: .atomic)
        }
        return PromptAttachment(url: url, mimeType: mimeType)
      } catch {
        return nil
      }
    }
  }

  nonisolated static func toolInputText(toolName: String, args: Any?) -> String? {
    // Pi exposes codemode as raw JavaScript to providers, while normal RPC tool
    // events/history use { code }. Accept both forms without re-encoding the script.
    if toolName == "codemode", let code = args as? String { return code }
    guard let args = args as? PiRPCClient.JSON else { return nil }
    switch toolName {
    case "codemode":
      return args["code"] as? String
    case "bash":
      guard let command = args["command"] as? String, !command.isEmpty else { return nil }
      return "$ \(command)"
    case "read":
      guard let path = args["path"] as? String, !path.isEmpty else { return nil }
      let offset = (args["offset"] as? NSNumber)?.intValue
      let limit = (args["limit"] as? NSNumber)?.intValue
      guard offset != nil || limit != nil else { return path }
      let firstLine = offset ?? 1
      if let limit { return "\(path):\(firstLine)-\(firstLine + max(limit - 1, 0))" }
      return "\(path):\(firstLine)"
    case "edit", "write":
      return args["path"] as? String
    case "fetch_content":
      if let url = args["url"] as? String { return url }
      if let urls = args["urls"] as? [String] { return urls.joined(separator: "\n") }
      return nil
    case "web_search":
      if let query = args["query"] as? String { return query }
      if let queries = args["queries"] as? [String] { return queries.joined(separator: " · ") }
      return nil
    case "source_check":
      return args["claim"] as? String
    case "generate_image":
      return args["prompt"] as? String
    default:
      return args["path"] as? String
    }
  }

  nonisolated private static func resultText(
    _ result: PiRPCClient.JSON,
    toolName: String? = nil,
    preferCompleteOutput: Bool = false
  ) -> String {
    let text = contentText(result["content"])

    // Pi intentionally truncates the final bash result to its context limit and
    // stores the complete output in a temporary file. Replacing the live preview
    // with that final result made long commands appear to contain only a tiny tail
    // (and a single very long line could appear to contain no output at all).
    if preferCompleteOutput, toolName == "bash",
      let details = result["details"] as? PiRPCClient.JSON,
      let truncation = details["truncation"] as? PiRPCClient.JSON,
      truncation["truncated"] as? Bool == true,
      let path = details["fullOutputPath"] as? String,
      let data = FileManager.default.contents(atPath: path), !data.isEmpty
    {
      return String(decoding: data, as: UTF8.self)
    }

    // An empty content array is a normal initial streaming update, not a useful
    // result to render. Results without a content field may still be structured
    // custom-tool values, for which the JSON fallback remains useful.
    if result["content"] != nil { return text }
    return prettyJSON(result)
  }

  nonisolated private static func prettyJSON(_ value: Any?) -> String {
    guard let value, JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  static func suggestedPiPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
      "\(home)/Library/pnpm/bin/pi",
      "/opt/homebrew/bin/pi",
      "/usr/local/bin/pi",
    ]
    return candidates.first(where: FileManager.default.isExecutableFile(atPath:)) ?? candidates[0]
  }
}

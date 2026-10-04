import Foundation

// One entry per day/model/session, rather than retaining full message bodies in the cache.
private struct UsageBucket: Codable {
  var day: Date
  var model: String
  var input = 0
  var output = 0
  var cacheRead = 0
  var cacheWrite = 0
  var tokens = 0
  var cost = 0.0
  var requests = 0
}

private struct UsageFileIndex: Codable {
  var size: Int64
  var modified: Date
  var project: String
  var buckets: [UsageBucket]
}

private struct UsageIndex: Codable {
  // Invalidate pre-hardening indexes, even when source files have not changed.
  var version: Int
  var root: String
  var files: [String: UsageFileIndex]
}

enum UsageScanner {
  // Scans from different period selections are serialized so an older scan cannot overwrite
  // a newer index. The lock also protects the on-disk index from concurrent read/write races.
  private nonisolated static let indexLock = NSLock()

  nonisolated static func scan(period: UsagePeriod) -> UsageSnapshot {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("PiMac/usage-index.json")
    return scan(root: root, startingAt: period.startDate, cacheURL: cache)
  }

  nonisolated static func scan(root: URL, startingAt startDate: Date?) -> UsageSnapshot {
    scan(root: root, startingAt: startDate, cacheURL: nil)
  }

  // cacheURL is injectable so tests can verify cache invalidation without touching the user's cache.
  nonisolated static func scan(root: URL, startingAt startDate: Date?, cacheURL: URL?)
    -> UsageSnapshot
  {
    indexLock.lock()
    defer { indexLock.unlock() }
    let fm = FileManager.default
    guard
      let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return UsageSnapshot() }

    var index: UsageIndex
    if let cacheURL, let data = try? Data(contentsOf: cacheURL),
      let saved = try? JSONDecoder().decode(UsageIndex.self, from: data), saved.root == root.path,
      saved.version == 3,
      saved.files.values.allSatisfy({ file in
        file.buckets.allSatisfy { bucket in
          [
            bucket.input, bucket.output, bucket.cacheRead, bucket.cacheWrite, bucket.tokens,
            bucket.requests,
          ].allSatisfy { $0 >= 0 }
            && bucket.cost.isFinite && bucket.cost >= 0
        }
      })
    {
      index = saved
    } else {
      index = UsageIndex(version: 3, root: root.path, files: [:])
    }
    var changed = false
    var seen = Set<String>()
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      let path = url.path
      seen.insert(path)
      guard
        let attributes = try? url.resourceValues(forKeys: [
          .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]),
        attributes.isRegularFile == true, attributes.isSymbolicLink != true,
        let size = attributes.fileSize, let modified = attributes.contentModificationDate
      else { continue }
      if let cached = index.files[path], cached.size == Int64(size), cached.modified == modified {
        continue
      }
      // A file can be appended while we're reading it. Keep the previous snapshot if the
      // metadata changes mid-scan, then retry on the next pass instead of losing its totals.
      if let parsed = parseFile(url, size: Int64(size), modified: modified) {
        index.files[path] = parsed
        changed = true
      }
    }
    let removed = index.files.keys.filter { !seen.contains($0) }
    for path in removed { index.files.removeValue(forKey: path) }
    if !removed.isEmpty { changed = true }
    if changed, let cacheURL, let data = try? JSONEncoder().encode(index) {
      try? fm.createDirectory(
        at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: cacheURL, options: .atomic)
    }

    let calendar = Calendar.current
    let startDay = startDate.map { calendar.startOfDay(for: $0) }
    var snapshot = UsageSnapshot()
    var days: [Date: UsageDay] = [:]
    var models: [String: ModelUsage] = [:]
    var projects: [String: ProjectUsage] = [:]
    for file in index.files.values {
      var sessionIncluded = false
      for bucket in file.buckets where startDay.map({ bucket.day >= $0 }) ?? true {
        snapshot.totalTokens = UsageArithmetic.add(snapshot.totalTokens, bucket.tokens)
        snapshot.inputTokens = UsageArithmetic.add(snapshot.inputTokens, bucket.input)
        snapshot.outputTokens = UsageArithmetic.add(snapshot.outputTokens, bucket.output)
        snapshot.cacheReadTokens = UsageArithmetic.add(snapshot.cacheReadTokens, bucket.cacheRead)
        snapshot.cacheWriteTokens = UsageArithmetic.add(
          snapshot.cacheWriteTokens, bucket.cacheWrite)
        snapshot.cost = UsageArithmetic.add(snapshot.cost, bucket.cost)
        snapshot.requests = UsageArithmetic.add(snapshot.requests, bucket.requests)
        sessionIncluded = true

        var day = days[bucket.day] ?? UsageDay(date: bucket.day, tokens: 0, cost: 0)
        day.tokens = UsageArithmetic.add(day.tokens, bucket.tokens)
        day.cost = UsageArithmetic.add(day.cost, bucket.cost)
        days[bucket.day] = day
        var model =
          models[bucket.model] ?? ModelUsage(name: bucket.model, tokens: 0, cost: 0, requests: 0)
        model.tokens = UsageArithmetic.add(model.tokens, bucket.tokens)
        model.cost = UsageArithmetic.add(model.cost, bucket.cost)
        model.requests = UsageArithmetic.add(model.requests, bucket.requests)
        models[bucket.model] = model
        var project =
          projects[file.project]
          ?? ProjectUsage(path: file.project, tokens: 0, cost: 0, sessions: 0)
        project.tokens = UsageArithmetic.add(project.tokens, bucket.tokens)
        project.cost = UsageArithmetic.add(project.cost, bucket.cost)
        projects[file.project] = project
      }
      if sessionIncluded {
        snapshot.sessions = UsageArithmetic.add(snapshot.sessions, 1)
        if var project = projects[file.project] {
          project.sessions = UsageArithmetic.add(project.sessions, 1)
          projects[file.project] = project
        }
      }
    }
    if let startDate {
      let end = calendar.startOfDay(for: .now)
      var date = calendar.startOfDay(for: startDate)
      while date <= end {
        if days[date] == nil { days[date] = UsageDay(date: date, tokens: 0, cost: 0) }
        guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
        date = next
      }
    }
    snapshot.days = days.values.sorted { $0.date < $1.date }
    snapshot.models = models.values.sorted {
      $0.tokens == $1.tokens ? $0.name < $1.name : $0.tokens > $1.tokens
    }
    snapshot.projects = projects.values.sorted {
      $0.tokens == $1.tokens ? $0.path < $1.path : $0.tokens > $1.tokens
    }
    return snapshot
  }

  private nonisolated static func parseFile(_ url: URL, size: Int64, modified: Date)
    -> UsageFileIndex?
  {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let decoder = JSONLineDecoder()
    var invalidHeader = false
    var project: String?
    var buckets: [String: UsageBucket] = [:]
    let calendar = Calendar.current
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let secondsFormatter = ISO8601DateFormatter()
    let usageMarker = Data("\"usage\"".utf8)
    var selectedModel: String?
    func consume(_ line: Data) {
      // Most lines are user messages, tool calls or events; avoid JSON decoding those bodies.
      if project != nil && !line.contains(usageMarker)
        && !line.contains(Data("\"model_change\"".utf8))
      {
        return
      }
      guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
      else { return }
      if project == nil {
        guard record["type"] as? String == "session" else {
          invalidHeader = true
          return
        }
        project = record["cwd"] as? String ?? "未知项目"
        return
      }
      let type = record["type"] as? String
      if type == "model_change" {
        selectedModel = record["modelId"] as? String
        return
      }
      let source: [String: Any]
      let model: String
      if type == "message", let message = record["message"] as? [String: Any] {
        let role = message["role"] as? String
        guard role == "assistant" || role == "toolResult" else { return }
        source = message
        // Nested usage can combine different models. Do not attribute it to the
        // selected chat model, and do not count nestedCalls/details usage twice.
        model =
          role == "toolResult"
          ? "工具内部调用 · \(message["toolName"] as? String ?? "tool")"
          : message["model"] as? String ?? selectedModel ?? "未知模型"
      } else if type == "usage" || type == "compaction" || type == "branch_summary" {
        source = record
        let details = record["details"] as? [String: Any]
        model =
          record["model"] as? String ?? details?["compactionModelId"] as? String
          ?? (type == "usage" ? "其他用量" : "摘要调用（模型未记录）")
      } else {
        return
      }
      guard let usage = source["usage"] as? [String: Any],
        let date = recordDate(
          record, message: source, fractionalFormatter: fractionalFormatter,
          secondsFormatter: secondsFormatter)
      else { return }
      let day = calendar.startOfDay(for: date)
      let key = "\(day.timeIntervalSince1970):\(model)"
      var bucket = buckets[key] ?? UsageBucket(day: day, model: model)
      let input = UsageArithmetic.integer(usage["input"])
      let output = UsageArithmetic.integer(usage["output"])
      let cacheRead = UsageArithmetic.integer(usage["cacheRead"])
      let cacheWrite = UsageArithmetic.integer(usage["cacheWrite"])
      bucket.input = UsageArithmetic.add(bucket.input, input)
      bucket.output = UsageArithmetic.add(bucket.output, output)
      bucket.cacheRead = UsageArithmetic.add(bucket.cacheRead, cacheRead)
      bucket.cacheWrite = UsageArithmetic.add(bucket.cacheWrite, cacheWrite)
      bucket.tokens = UsageArithmetic.add(
        bucket.tokens,
        UsageArithmetic.integer(
          usage["totalTokens"],
          fallback: UsageArithmetic.add(
            UsageArithmetic.add(input, output), UsageArithmetic.add(cacheRead, cacheWrite))))
      let costObject = usage["cost"] as? [String: Any]
      bucket.cost = UsageArithmetic.add(
        bucket.cost, UsageArithmetic.cost(costObject?["total"] ?? usage["cost"]))
      bucket.requests = UsageArithmetic.add(bucket.requests, 1)
      buckets[key] = bucket
    }
    do {
      // Do not chase a continuously growing transcript. The final metadata check rejects
      // this snapshot and lets the next scan retry at a new, finite boundary.
      var remaining = size
      while remaining > 0 {
        guard let chunk = try handle.read(upToCount: Int(min(remaining, 64 * 1024))),
          !chunk.isEmpty
        else { return nil }
        remaining -= Int64(chunk.count)
        for line in decoder.append(chunk) {
          consume(line)
          if invalidHeader { return nil }
        }
      }
      if let last = decoder.finish() { consume(last) }
    } catch { return nil }
    guard !invalidHeader, let project else { return nil }
    // If the file grew during parsing, retry on the next scan instead of persisting stale data.
    guard
      // URL caches resource values. Use a new URL to actually re-stat after reading.
      let attributes = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [
        .fileSizeKey, .contentModificationDateKey,
      ]),
      attributes.fileSize.map(Int64.init) == size, attributes.contentModificationDate == modified
    else { return nil }
    return UsageFileIndex(
      size: size, modified: modified, project: project, buckets: Array(buckets.values))
  }

  private nonisolated static func recordDate(
    _ record: [String: Any], message: [String: Any],
    fractionalFormatter: ISO8601DateFormatter, secondsFormatter: ISO8601DateFormatter
  ) -> Date? {
    if let timestamp = record["timestamp"] as? String {
      if let date = fractionalFormatter.date(from: timestamp) { return date }
      if let date = secondsFormatter.date(from: timestamp) { return date }
    }
    return AccountUsageSnapshot.date(message["timestamp"], milliseconds: true)
  }
}

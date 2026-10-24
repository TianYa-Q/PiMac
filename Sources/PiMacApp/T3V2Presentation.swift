import Foundation

/// Pure presentation mapping, not a second orchestration engine or persisted projection.
/// All writes use the official V2 commands and all identity comes from the server.
enum T3V2Presentation {
  typealias JSON = [String: Any]
  static let active = ["preparing", "starting", "running", "waiting", "interrupting"]

  static func state(_ status: String) -> String {
    if active.contains(status) { return "running" }
    if status == "failed" { return "error" }
    if status == "cancelled" || status == "interrupted" { return "interrupted" }
    return status
  }

  /// 只认服务端的 subagent 关系；fork 同样有父线程，但不是委派的子代理。
  static func subagentParentID(_ thread: JSON) -> String? {
    guard let lineage = thread["lineage"] as? JSON,
      lineage["relationshipToParent"] as? String == "subagent",
      let parentID = lineage["parentThreadId"] as? String,
      !parentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      parentID != thread["id"] as? String
    else { return nil }
    return parentID
  }

  /// 运行提示沿委派链向上传递，但不改写服务端状态；fork 不继承，损坏的环也必须终止。
  static func runningThreadIDs(threads: [JSON], locallyRunningIDs: Set<String>) -> Set<String> {
    var parents: [String: String] = [:]
    var running = locallyRunningIDs
    for thread in threads {
      guard let id = thread["id"] as? String else { continue }
      if let parentID = subagentParentID(thread) { parents[id] = parentID }
      if active.contains(thread["status"] as? String ?? "") { running.insert(id) }
    }
    var pending = Array(running)
    while let id = pending.popLast() {
      if let parentID = parents[id], running.insert(parentID).inserted {
        pending.append(parentID)
      }
    }
    return running
  }

  @MainActor
  static func hasUnreadCompletion(_ thread: JSON) -> Bool {
    guard thread["status"] as? String == "completed" else { return false }
    let completed = T3DesktopClient.date(thread["latestRunCompletedAt"])
    guard completed != .distantPast else { return false }
    return completed > T3DesktopClient.date(thread["lastVisitedAt"])
  }

  static func thread(_ native: JSON, run: JSON? = nil) -> JSON {
    var result = native
    let status = run?["status"] as? String ?? native["status"] as? String ?? "idle"
    let id = run?["id"] as? String ?? native["latestRunId"] as? String
    if let id {
      result["latestTurn"] = [
        "turnId": id, "state": state(status),
        "startedAt": run?["startedAt"] ?? native["latestRunStartedAt"] ?? NSNull(),
        "completedAt": run?["completedAt"] ?? native["latestRunCompletedAt"] ?? NSNull(),
      ]
    }
    result["session"] = [
      "status": active.contains(status) ? "running" : status == "failed" ? "error" : "ready"
    ]
    return result
  }

  static func shell(_ native: JSON) -> JSON {
    var result = native
    result["threads"] = (native["threads"] as? [JSON] ?? []).map { thread($0) }
    return result
  }

  static func detail(_ native: JSON) -> JSON {
    guard let projection = native["projection"] as? JSON,
      let appThread = projection["thread"] as? JSON
    else { return native }
    let runs = projection["runs"] as? [JSON] ?? []
    // 排队消息尚未执行，不能覆盖刚停止的任务，否则取消结果会被映射成 idle。
    let currentRun =
      runs.last(where: { active.contains($0["status"] as? String ?? "") })
      ?? runs.last(where: { $0["status"] as? String != "queued" })
    var result = thread(appThread, run: currentRun)
    // 不回退到其他 provider thread：切换 Provider 后旧目标不属于当前会话执行者。
    let providerThreads = projection["providerThreads"] as? [JSON] ?? []
    let activeProviderID = appThread["activeProviderThreadId"] as? String
    let provider = providerThreads.first {
      guard let activeProviderID else { return false }
      return $0["id"] as? String == activeProviderID
    }
    result["goal"] = provider?["goal"] ?? NSNull()
    result["goalDriver"] = provider?["driver"] ?? NSNull()
    let rows = projection["visibleTurnItems"] as? [JSON] ?? []
    let items = rows.compactMap { $0["item"] as? JSON }
    var messages: [JSON] = []
    var activities: [JSON] = []
    for item in items {
      let type = item["type"] as? String ?? ""
      let date = item["startedAt"] as? String ?? item["updatedAt"] as? String ?? ""
      switch type {
      case "user_message", "assistant_message", "reasoning":
        messages.append([
          "id": item["id"] ?? "", "messageId": item["messageId"] ?? item["id"] ?? "",
          "role": type == "user_message" ? "user" : type == "reasoning" ? "reasoning" : "assistant",
          "text": item["text"] ?? "", "streaming": item["streaming"] ?? false,
          "attachments": item["attachments"] ?? [], "createdAt": date,
          "runId": item["runId"] ?? NSNull(),
        ])
      case "compaction":
        let before = item["beforeTokenCount"] as? Int
        let after = item["afterTokenCount"] as? Int
        let counts =
          before.map { value in
            after.map { " \(value.formatted()) → \($0.formatted()) tokens" }
              ?? " \(value.formatted()) tokens"
          } ?? ""
        messages.append([
          "id": item["id"] ?? "", "role": "compaction",
          "title": "上下文已压缩" + counts,
          "text": item["summary"] ?? "", "createdAt": date,
          "runId": item["runId"] ?? NSNull(),
        ])
      case "command_execution", "dynamic_tool", "file_change", "file_search", "web_search", "error",
        "system_notice":
        let status = item["status"] as? String ?? "completed"
        let tool = !["error", "system_notice", "compaction"].contains(type)
        let nativeName =
          item["toolName"] as? String ?? item["title"] as? String
          ?? (type == "file_change" ? "edit" : type == "command_execution" ? "bash" : type)
        // 只翻译服务端错误状态标题，不改工具名、原始诊断或未知标题。
        let name: String
        switch (type, nativeName) {
        case ("error", "Provider retry"): name = "正在重试"
        case ("error", "Provider recovered"): name = "已恢复"
        case ("error", "Provider retry stopped"): name = "重试已停止"
        default: name = nativeName
        }
        var data: JSON = ["toolName": name, "input": item["input"] ?? [:]]
        if status == "completed",
          let page = item["htmlRender"] as? T3HTMLRender
            ?? T3HTMLRender.read(toolName: name, output: item["output"])
        {
          // 页面独立于折叠的工作过程显示；历史快照与实时结果走同一条映射路径。
          messages.append([
            "id": "\(item["id"] as? String ?? "")-html", "role": "assistant",
            "text": "", "streaming": false, "htmlRender": page, "createdAt": date,
            "htmlDocument": item["htmlDocument"] ?? NSNull(),
            "htmlRenderError": item["htmlRenderError"] ?? NSNull(),
            "runId": item["runId"] ?? NSNull(),
          ])
        }
        if let images = item["localImages"] as? [PromptAttachment], !images.isEmpty {
          // Keep generated images visible even when the work/tool group is collapsed.
          messages.append([
            "id": "\(item["id"] as? String ?? "")-images", "role": "assistant",
            "text": "", "streaming": false, "localImages": images, "createdAt": date,
            "runId": item["runId"] ?? NSNull(),
          ])
        }
        if let parent = item["parentItemId"] as? String {
          data["parentToolCallId"] = parent
        }
        // V2 command items carry a plain string, while the transcript renderer
        // expects bash arguments. Normalize here for both live and saved history.
        if type == "command_execution", let command = item["input"] as? String {
          data["toolName"] = "bash"
          data["input"] = ["command": command]
        }
        if type == "file_change", let path = item["fileName"] as? String {
          data["input"] = ["path": path]
        }
        if let output = item["output"] as? JSON, output["content"] != nil {
          data["rawOutput"] = output
        }
        if let diff = item["diffStr"] as? String, !diff.isEmpty {
          data["diff"] = diff
        } else if type == "file_change" {
          let old = item["oldStr"] as? String
          let new = item["newStr"] as? String
          if old != nil || new != nil {
            data["diff"] = [
              old.map { $0.components(separatedBy: "\n").map { "-" + $0 }.joined(separator: "\n") },
              new.map { $0.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n") },
            ].compactMap { $0 }.joined(separator: "\n")
          }
        }
        let failure = item["failure"] as? JSON
        let detail =
          item["output"] as? String ?? failure?["message"] as? String ?? item["message"] as? String
          ?? item["summary"] as? String ?? ""
        activities.append([
          "id": item["id"] ?? "", "turnId": item["runId"] ?? "",
          "kind": tool
            ? (status == "failed"
              ? "tool.failed" : active.contains(status) ? "tool.started" : "tool.completed")
            : type == "error" ? "error" : "warning",
          "summary": name, "createdAt": date,
          "payload": [
            "toolCallId": item["id"] ?? "", "title": name, "detail": detail,
            "status": active.contains(status) ? "inProgress" : status, "data": data,
          ],
        ])
      default: break
      }
    }
    // The queue comes from runs/messages, not visible timeline items.
    let sourceMessages = projection["messages"] as? [JSON] ?? []
    result["queueHeld"] = runs.contains {
      $0["status"] as? String == "queued" && $0["queueHeld"] as? Bool == true
    }
    let queuedRuns = runs.filter { $0["status"] as? String == "queued" }
    // 队列与历史消息按身份连接，而非逐个扫描；重复 ID 和缺失 ID 均保持原先第一个匹配项的语义。
    var messagesByID: [String: JSON] = [:]
    var messageWithoutID: JSON?
    if !queuedRuns.isEmpty {
      for message in sourceMessages {
        if let id = message["id"] as? String {
          if messagesByID[id] == nil { messagesByID[id] = message }
        } else if messageWithoutID == nil {
          messageWithoutID = message
        }
      }
    }
    result["queuedMessages"] =
      queuedRuns
      .sorted {
        let left = $0["queuePosition"] as? Int ?? $0["ordinal"] as? Int ?? 0
        let right = $1["queuePosition"] as? Int ?? $1["ordinal"] as? Int ?? 0
        return left == right
          ? ($0["ordinal"] as? Int ?? 0) < ($1["ordinal"] as? Int ?? 0) : left < right
      }.compactMap { run -> JSON? in
        let messageID = run["userMessageId"] as? String
        guard
          let message = messageID.flatMap({ messagesByID[$0] })
            ?? (messageID == nil ? messageWithoutID : nil)
        else { return nil }
        var queued = message
        queued["runId"] = run["id"]
        return queued
      }
    // Server 接收用户消息早于 Provider 创建 turn item；重开会话也必须显示已提交正文。
    // 排队消息仍只放在可编辑队列中，取消队列时不能遗留虚假的历史记录。
    let queuedMessageIDs = Set(
      runs.filter {
        ["queued", "cancelled"].contains($0["status"] as? String ?? "")
      }.compactMap { $0["userMessageId"] as? String })
    var visibleMessageIDs = Set(messages.compactMap { $0["messageId"] as? String })
    for message in sourceMessages {
      guard message["role"] as? String == "user", let id = message["id"] as? String,
        !queuedMessageIDs.contains(id), visibleMessageIDs.insert(id).inserted
      else { continue }
      var visible = message
      visible["messageId"] = id
      visible["streaming"] = false
      messages.append(visible)
    }
    result["messages"] = messages
    result["activities"] = activities
    var detail: JSON = ["snapshotSequence": native["snapshotSequence"] ?? -1, "thread": result]
    if let stats = stats(native), let data = try? JSONEncoder().encode(stats),
      let metrics = try? JSONSerialization.jsonObject(with: data)
    {
      detail["sessionStats"] = metrics
    }
    return detail
  }

  private static let contextTimestampLock = NSLock()
  private static let contextSecondsFormatter = ISO8601DateFormatter()
  private static let contextFractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static func contextTimestamp(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    // 后台会话并行映射时，复用的 Foundation formatter 不能被并发访问。
    contextTimestampLock.lock()
    defer { contextTimestampLock.unlock() }
    return contextFractionalFormatter.date(from: text) ?? contextSecondsFormatter.date(from: text)
  }

  /// Compaction is an official context observation too. Older Pi versions only
  /// publish tokenUsage when the task settles, even after many tool/model calls.
  /// Use the local main-agent compaction estimate until a newer usage arrives.
  private static func contextMetrics(_ projection: JSON, turns: [JSON])
    -> (used: Int, window: Int, estimated: Bool)?
  {
    let usageTurn = turns.last(where: { $0["tokenUsage"] is JSON })
    let usage = usageTurn?["tokenUsage"] as? JSON
    let usageDate =
      contextTimestamp(usage?["updatedAt"])
      ?? contextTimestamp(usageTurn?["completedAt"])
      ?? contextTimestamp(usageTurn?["startedAt"])
    let turnIDs = Set(turns.compactMap { $0["id"] as? String })
    // Deliberately exclude inherited visible history and child tool/subagent items.
    // 每条候选只解析一次日期，单遍取最大值，平手仍保留第一条。
    var compaction: (date: Date, after: Int)?
    for item in projection["turnItems"] as? [JSON] ?? [] {
      guard item["type"] as? String == "compaction",
        item["status"] as? String == "completed",
        item["parentItemId"] == nil || item["parentItemId"] is NSNull,
        let turnID = item["providerTurnId"] as? String, turnIDs.contains(turnID),
        let after = item["afterTokenCount"] as? Int, after >= 0,
        let date = contextTimestamp(item["completedAt"] ?? item["updatedAt"])
      else { continue }
      // Without a timestamp on existing usage, prefer it rather than risk
      // replacing a newer measurement with an old estimate.
      guard usage == nil || usageDate.map({ date > $0 }) == true else { continue }
      if compaction.map({ date > $0.date }) ?? true { compaction = (date, after) }
    }
    if let compaction {
      return (compaction.after, usage?["maxTokens"] as? Int ?? 0, true)
    }
    guard let usage else { return nil }
    return (usage["usedTokens"] as? Int ?? 0, usage["maxTokens"] as? Int ?? 0, false)
  }

  static func stats(_ native: JSON) -> SessionStats? {
    let projection = native["projection"] as? JSON ?? [:]
    let turns = projection["providerTurns"] as? [JSON] ?? []
    let context = contextMetrics(projection, turns: turns)
    let runs = projection["runs"] as? [JSON] ?? []
    let run = runs.last(where: { active.contains($0["status"] as? String ?? "") }) ?? runs.last
    let attempts = projection["attempts"] as? [JSON] ?? []
    let attemptIDs = Set(
      attempts.filter { $0["runId"] as? String == run?["id"] as? String }
        .compactMap { $0["id"] as? String })
    let latest =
      run == nil
      ? turns.last
      : turns.last(where: {
        guard let id = $0["runAttemptId"] as? String else { return false }
        return attemptIDs.contains(id)
      })
    let outputUsage = latest?["turnTokenUsage"] as? JSON
    // Only display calibrated streaming measurements. Legacy whole-request
    // timing is not comparable to AA, so do not silently fall back to it.
    let piMetrics = latest?["piMetrics"] as? JSON
    let measuredTokens =
      piMetrics?["speedTokens"] as? Double
      ?? (piMetrics?["speedTokens"] as? Int).map(Double.init) ?? 0
    let durationMs =
      piMetrics?["speedDurationMs"] as? Double
      ?? (piMetrics?["speedDurationMs"] as? Int).map(Double.init) ?? 0
    let measuredSpeed = measuredTokens * 1000 / durationMs
    let validSpeed =
      piMetrics?["speedMethod"] as? String == "aa-approx-v1"
      && measuredTokens > 0 && durationMs > 0 && measuredSpeed.isFinite
    // Session billing/cache counters come from per-turn usage, never context
    // snapshots (which overlap across requests). Recompute from the projection
    // so refreshes and in-progress metric updates cannot double-count a turn.
    let turnUsages = turns.compactMap { $0["turnTokenUsage"] as? JSON }
    guard context != nil || outputUsage != nil || !turnUsages.isEmpty else { return nil }
    let used = context?.used ?? 0
    let max = context?.window ?? 0
    var input = 0
    var cached = 0
    var creation = 0
    for turnUsage in turnUsages {
      let reads = turnUsage["cachedInputTokens"] as? Int ?? 0
      let writes = turnUsage["cacheCreationTokens"] as? Int ?? 0
      // Normalized turn input includes cache reads/writes; SessionStats does not.
      input += Swift.max(0, (turnUsage["inputTokens"] as? Int ?? 0) - reads - writes)
      cached += reads
      creation += writes
    }
    let costs = turns.compactMap { turn -> Double? in
      guard let metrics = turn["piMetrics"] as? JSON,
        let cost = metrics["totalCostUsd"] as? Double, cost.isFinite, cost >= 0
      else { return nil }
      return cost
    }
    return SessionStats(
      cost: costs.isEmpty ? nil : costs.reduce(0, +),
      contextPercent: max > 0 ? Double(used) / Double(max) * 100 : nil,
      totalTokens: used, inputTokens: input, cacheReadTokens: cached, cacheWriteTokens: creation,
      outputTokensPerSecond: validSpeed ? measuredSpeed : nil,
      contextWindow: max > 0 ? max : nil,
      contextIsEstimated: context?.estimated == true ? true : nil)
  }

  static func requests(_ native: JSON) -> JSON {
    let projection = native["projection"] as? JSON ?? [:]
    let pending = Set(
      (projection["runtimeRequests"] as? [JSON] ?? []).filter {
        $0["status"] as? String == "pending"
      }.compactMap { $0["id"] as? String })
    let items = projection["turnItems"] as? [JSON] ?? []
    let dialogs: [JSON] = items.compactMap { item in
      guard let id = item["requestId"] as? String, pending.contains(id) else { return nil }
      let title = item["title"] as? String ?? "Pi"
      if item["type"] as? String == "approval_request" {
        return ["id": id, "method": "confirm", "title": title, "message": item["prompt"] ?? ""]
      }
      guard item["type"] as? String == "user_input_request",
        let questions = item["questions"] as? [JSON], questions.count == 1,
        let question = questions.first
      else { return nil }
      let options = question["options"] as? [JSON] ?? []
      if !options.isEmpty {
        return [
          "id": id, "method": "select", "title": question["question"] ?? title,
          "options": options.compactMap { $0["value"] as? String ?? $0["label"] as? String },
        ]
      }
      return ["id": id, "method": "input", "title": question["question"] ?? title]
    }
    return [
      "epoch": (projection["thread"] as? JSON)?["id"] ?? "", "requests": dialogs, "events": [],
    ]
  }
}

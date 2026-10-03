import Foundation

/// Pure presentation mapping, not a second orchestration engine or persisted projection.
/// All writes use the official V2 commands and all identity comes from the server.
@MainActor
enum T3V2Presentation {
  typealias JSON = [String: Any]
  static let active = ["preparing", "starting", "running", "waiting", "interrupting"]

  static func state(_ status: String) -> String {
    if active.contains(status) { return "running" }
    if status == "failed" { return "error" }
    if status == "cancelled" || status == "interrupted" { return "interrupted" }
    return status
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
    let currentRun =
      runs.last(where: { active.contains($0["status"] as? String ?? "") }) ?? runs.last
    var result = thread(appThread, run: currentRun)
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
          "id": item["id"] ?? "",
          "role": type == "user_message" ? "user" : type == "reasoning" ? "reasoning" : "assistant",
          "text": item["text"] ?? "", "streaming": item["streaming"] ?? false,
          "attachments": item["attachments"] ?? [], "createdAt": date,
        ])
      case "command_execution", "dynamic_tool", "file_change", "file_search", "web_search", "error",
        "system_notice", "compaction":
        let status = item["status"] as? String ?? "completed"
        let tool = !["error", "system_notice", "compaction"].contains(type)
        let name =
          item["toolName"] as? String ?? item["title"] as? String
          ?? (type == "file_change" ? "edit" : type == "command_execution" ? "bash" : type)
        var data: JSON = ["toolName": name, "input": item["input"] ?? [:]]
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

  static func stats(_ native: JSON) -> SessionStats? {
    let projection = native["projection"] as? JSON ?? [:]
    let turns = projection["providerTurns"] as? [JSON] ?? []
    // A newly started turn may not have usage yet. Keep the latest known context
    // instead of hiding all metrics until that turn finishes.
    let usage = turns.last(where: { $0["tokenUsage"] is JSON })?["tokenUsage"] as? JSON
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
    let output = outputUsage?["outputTokens"] as? Int ?? 0
    var duration = (outputUsage?["assistantDurationMs"] as? Double ?? 0) / 1000
    if duration <= 0, let started = latest?["startedAt"] as? String,
      let completed = latest?["completedAt"] as? String
    {
      duration = T3DesktopClient.date(completed).timeIntervalSince(T3DesktopClient.date(started))
    }
    guard usage != nil || (output > 0 && duration > 0) else { return nil }
    let used = usage?["usedTokens"] as? Int ?? 0
    let max = usage?["maxTokens"] as? Int ?? 0
    let input = usage?["inputTokens"] as? Int ?? 0
    let cached = usage?["cachedInputTokens"] as? Int ?? 0
    return SessionStats(
      cost: nil, contextPercent: max > 0 ? Double(used) / Double(max) * 100 : nil,
      totalTokens: used, inputTokens: input, cacheReadTokens: cached, cacheWriteTokens: 0,
      outputTokensPerSecond: output > 0 && duration > 0 ? Double(output) / duration : nil,
      contextWindow: max > 0 ? max : nil)
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

import Foundation

/// Server-owned read model. Retain the original fields when editing policies the UI does not expose.
struct DesktopScheduledTask: Identifiable {
  let raw: [String: Any]
  let id: String
  let title: String
  let enabled: Bool

  init(_ raw: [String: Any]) throws {
    guard let id = raw["id"] as? String, let title = raw["title"] as? String,
      let enabled = raw["enabled"] as? Bool,
      raw["schedule"] is [String: Any], raw["modelSelection"] is [String: Any]
    else { throw T3DesktopClient.ClientError.rejected }
    self.raw = raw
    self.id = id
    self.title = title
    self.enabled = enabled
  }

  var projectID: String { raw["projectId"] as? String ?? "" }
  var threadID: String? { raw["threadId"] as? String }
  var prompt: String { raw["prompt"] as? String ?? "" }
  var scheduleLabel: String {
    let schedule = raw["schedule"] as? [String: Any] ?? [:]
    if schedule["type"] as? String == "interval" {
      let minutes = Double(schedule["everyMs"] as? Int ?? 0) / 60000
      return "每 \(minutes.formatted(.number.precision(.fractionLength(0...3)))) 分钟"
    }
    let days = schedule["weekdays"] as? [Int]
    let labels = ["日", "一", "二", "三", "四", "五", "六"]
    let dayLabel =
      days.map {
        $0.filter { labels.indices.contains($0) }.map { labels[$0] }.joined(separator: "、")
      } ?? "每天"
    return "\(dayLabel) \(schedule["timeOfDay"] as? String ?? "")"
  }
  var runStatusLabel: String {
    switch raw["lastRunStatus"] as? String {
    case "running": return "正在派发"
    case "succeeded": return "派发成功"
    case "failed": return "派发失败"
    default: return "尚未运行"
    }
  }
}

struct ScheduledTaskDraft: Identifiable {
  let id: String
  let commandID = UUID().uuidString
  let original: DesktopScheduledTask?
  var title = ""
  var prompt = ""
  var enabled = true
  var projectID = ""
  var threadID = ""
  var modelInstanceID = "pi"
  var modelID = ""
  var scheduleType = "interval"
  var intervalMinutes = "60"
  var timeOfDay = "09:00"
  var weekdays: Set<Int> = Set(0...6)
  var runtimeMode = "full-access"
  var interactionMode = "default"

  init(task: DesktopScheduledTask? = nil, projectID: String = "", modelID: String = "") {
    original = task
    id = task?.id ?? UUID().uuidString
    self.projectID = task?.projectID ?? projectID
    self.modelID = modelID
    guard let task else { return }
    title = task.title
    prompt = task.prompt
    enabled = task.enabled
    threadID = task.threadID ?? ""
    let selection = task.raw["modelSelection"] as? [String: Any] ?? [:]
    self.modelID = selection["model"] as? String ?? ""
    modelInstanceID = selection["instanceId"] as? String ?? "pi"
    runtimeMode = task.raw["runtimeMode"] as? String ?? "full-access"
    interactionMode = task.raw["interactionMode"] as? String ?? "default"
    let schedule = task.raw["schedule"] as? [String: Any] ?? [:]
    scheduleType = schedule["type"] as? String ?? "interval"
    intervalMinutes = String(Double(schedule["everyMs"] as? Int ?? 3_600_000) / 60000)
    timeOfDay = schedule["timeOfDay"] as? String ?? "09:00"
    weekdays = Set(schedule["weekdays"] as? [Int] ?? Array(0...6))
  }

  var validationMessage: String? {
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入标题。" }
    if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入任务提示词。" }
    if projectID.isEmpty || modelID.isEmpty || modelInstanceID.isEmpty { return "请选择项目和模型。" }
    if scheduleType == "interval" {
      guard let minutes = Double(intervalMinutes), minutes.isFinite, minutes >= 1,
        minutes * 60000 <= 9_007_199_254_740_991
      else { return "间隔至少为 1 分钟，且不能超出 Server 的安全整数范围。" }
    } else if scheduleType == "fixed_time" {
      guard
        timeOfDay.range(of: #"\A([01]?[0-9]|2[0-3]):[0-5][0-9]\z"#, options: .regularExpression)
          != nil,
        !weekdays.isEmpty, weekdays.allSatisfy({ (0...6).contains($0) })
      else { return "请输入有效的 HH:MM，并至少选择一天。" }
    } else {
      return "不支持的调度类型。"
    }
    return nil
  }

  func payload() throws -> [String: Any] {
    guard validationMessage == nil else { throw T3DesktopClient.ClientError.rejected }
    var selection = original?.raw["modelSelection"] as? [String: Any] ?? [:]
    if selection["model"] as? String != modelID
      || selection["instanceId"] as? String != modelInstanceID
    {
      selection = [:]
    }
    selection["instanceId"] = modelInstanceID
    selection["model"] = modelID
    let schedule: [String: Any] =
      scheduleType == "interval"
      ? ["type": "interval", "everyMs": Int(Double(intervalMinutes)! * 60000)]
      : ["type": "fixed_time", "timeOfDay": timeOfDay, "weekdays": weekdays.sorted()]
    var fields: [String: Any] = [
      "id": id, "commandId": commandID,
      "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
      "prompt": prompt.trimmingCharacters(in: .whitespacesAndNewlines), "enabled": enabled,
      "projectId": projectID, "threadId": threadID.isEmpty ? NSNull() : threadID as Any,
      "modelSelection": selection, "schedule": schedule,
      "workspaceStrategy": original?.raw["workspaceStrategy"] ?? ["type": "root"],
      "runtimeMode": runtimeMode, "interactionMode": interactionMode,
    ]
    if let original {
      fields["requireExisting"] = true
      fields["createdBy"] = original.raw["createdBy"]
      fields["creationSource"] = original.raw["creationSource"]
    } else {
      fields["createdBy"] = "user"
      fields["creationSource"] = "web"
    }
    return fields
  }
}

import Foundation

/// A read-only snapshot shared by status surfaces. No process is resumed to collect it.
struct ProjectActivitySummary {
  let project: WorkspaceProject
  let isSelected: Bool
  var running = 0
  var queued = 0
  var ready = 0
  var connecting = 0
  var failed = 0
  var confirmations = 0
  var delivering = 0
  var undelivered = 0
  var details: [String] = []
}

@MainActor
enum ProjectStatusOverview {
  static let pageSize = 10

  static func summaries(
    projects: [WorkspaceProject], models: [AppModel], selectedProjectPath: String?,
    remoteQueueCounts: [ObjectIdentifier: Int] = [:],
    pendingReplyModels: Set<ObjectIdentifier> = [],
    confirmationModels: Set<ObjectIdentifier> = [],
    undeliveredCounts: [String: Int] = [:]
  ) -> [ProjectActivitySummary] {
    var seen: Set<ObjectIdentifier> = []
    let uniqueModels = models.filter { seen.insert(ObjectIdentifier($0)).inserted }
    return projects.map { project in
      var summary = ProjectActivitySummary(
        project: project, isSelected: project.id == selectedProjectPath)
      summary.undelivered = undeliveredCounts[project.id] ?? 0
      for model in uniqueModels where model.projectURL?.standardizedFileURL.path == project.id {
        let id = ObjectIdentifier(model)
        summary.queued += model.queuedPrompts.count + (remoteQueueCounts[id] ?? 0)
        if confirmationModels.contains(id) { summary.confirmations += 1 }
        if model.isBusy || model.awaitingAgentStart {
          summary.running += 1
          let title =
            model.sessionName.isEmpty
            ? model.messages.first(where: { $0.kind == .user })?.text ?? "任务"
            : model.sessionName
          let phase = model.isCompacting ? "压缩中" : model.codexRotationInFlight ? "切换账户" : "执行中"
          summary.details.append("\(phase)：\(compact(title, limit: 55))")
        } else if pendingReplyModels.contains(id) {
          summary.delivering += 1
        }
        switch model.connectionState {
        case .connecting:
          summary.connecting += 1
        case .connected where model.isLoadingConfiguration:
          summary.connecting += 1
        case .connected where !model.isBusy && !model.awaitingAgentStart:
          if !pendingReplyModels.contains(id), !confirmationModels.contains(id) {
            summary.ready += 1
          }
        case .failed(let reason):
          summary.failed += 1
          summary.details.append("连接失败：\(compact(reason, limit: 55))")
        default: break
        }
      }
      return summary
    }
  }

  /// Include active work and actionable blockers, not merely running processes.
  static func visibleSummaries(_ summaries: [ProjectActivitySummary]) -> [ProjectActivitySummary] {
    summaries.filter {
      $0.running > 0 || $0.queued > 0 || $0.confirmations > 0
        || $0.delivering > 0 || $0.undelivered > 0 || $0.failed > 0
    }
  }

  static func page(_ requested: Int, count: Int) -> Int {
    min(max(1, requested), max(1, (count + pageSize - 1) / pageSize))
  }

  static func message(
    _ summaries: [ProjectActivitySummary], page requested: Int = 1,
    otherProjectsOnly: Bool = false
  ) -> String {
    guard !summaries.isEmpty else { return "尚无项目 · 请在 Mac 添加" }
    let page = page(requested, count: summaries.count)
    let pages = max(1, (summaries.count + pageSize - 1) / pageSize)
    let running = summaries.reduce(0) { $0 + $1.running }
    let queued = summaries.reduce(0) { $0 + $1.queued }
    var lines = [
      "📊 \(otherProjectsOnly ? "其他活跃或需关注的项目" : "活跃或需关注的项目")（\(page)/\(pages)）",
      "\(summaries.count) 项目 · \(running) 执行 · \(queued) 排队", "",
    ]
    for (offset, summary) in summaries.dropFirst((page - 1) * pageSize).prefix(pageSize)
      .enumerated()
    {
      let index = (page - 1) * pageSize + offset + 1
      lines.append(
        "\(summary.isSelected ? "▶️" : "📁") \(index). \(compact(summary.project.name, limit: 45))\(summary.isSelected ? "（当前 Telegram）" : "")"
      )
      var states: [String] = []
      if summary.running > 0 { states.append("⚡ \(summary.running) 执行") }
      if summary.queued > 0 { states.append("📥 \(summary.queued) 排队") }
      if summary.confirmations > 0 { states.append("⏸ \(summary.confirmations) 待确认") }
      if summary.delivering > 0 { states.append("📤 \(summary.delivering) 回传中") }
      if summary.undelivered > 0 { states.append("⚠️ \(summary.undelivered) 未送达") }
      if summary.connecting > 0 { states.append("⏳ \(summary.connecting) 连接中") }
      if summary.ready > 0 { states.append("✅ \(summary.ready) 就绪") }
      if summary.failed > 0 { states.append("🔴 \(summary.failed) 连接失败") }
      lines.append(states.isEmpty ? "   💤 空闲（未启动或已挂起）" : "   " + states.joined(separator: " · "))
      if let detail = summary.details.first { lines.append("   \(compact(detail, limit: 64))") }
      lines.append("")
    }
    if otherProjectsOnly {
      lines.append("含桌面任务 · 不含上方项目\n仅供查看，切换用 /projects。")
    } else {
      lines.append("含桌面任务 · ▶️ 当前 Telegram 项目")
    }
    return lines.joined(separator: "\n")
  }

  private static func compact(_ text: String, limit: Int) -> String {
    let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return text.count > limit ? String(text.prefix(limit)) + "…" : text
  }
}

import Foundation

/// Pure list projection shared by the scheduler UI and regression tests.
enum ScheduledTaskFilter: String, CaseIterable, Identifiable {
  case all, enabled, paused, running, failed
  var id: Self { self }
  var title: String {
    switch self {
    case .all: return "全部"
    case .enabled: return "已启用"
    case .paused: return "已暂停"
    case .running: return "正在派发"
    case .failed: return "派发失败"
    }
  }

  func includes(_ task: DesktopScheduledTask) -> Bool {
    switch self {
    case .all: return true
    case .enabled: return task.enabled
    case .paused: return !task.enabled
    case .running: return task.raw["lastRunStatus"] as? String == "running"
    case .failed: return task.raw["lastRunStatus"] as? String == "failed"
    }
  }
}

enum ScheduledTaskSort: String, CaseIterable, Identifiable {
  case title, nextRun, lastRun
  var id: Self { self }
  var title: String {
    switch self {
    case .title: return "按标题"
    case .nextRun: return "即将执行"
    case .lastRun: return "最近派发"
    }
  }
}

enum ScheduledTaskPresentation {
  @MainActor
  static func visibleTasks(
    _ tasks: [DesktopScheduledTask], query: String, filter: ScheduledTaskFilter,
    projectTitles: [String: String] = [:], sort: ScheduledTaskSort = .title
  ) -> [DesktopScheduledTask] {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    let filtered = tasks.filter { task in
      guard filter.includes(task) else { return false }
      let selection = task.raw["modelSelection"] as? [String: Any] ?? [:]
      let text = [
        task.title, task.prompt, projectTitles[task.projectID] ?? "",
        selection["model"] as? String ?? "", task.raw["lastRunError"] as? String ?? "",
      ]
      .joined(separator: "\n")
      return terms.allSatisfy { text.localizedStandardContains($0) }
    }
    return filtered.sorted { lhs, rhs in
      if sort != .title {
        let key = sort == .nextRun ? "nextRunAt" : "lastRunAt"
        let left = T3DesktopClient.date(lhs.raw[key])
        let right = T3DesktopClient.date(rhs.raw[key])
        let leftValid = left != .distantPast && (sort != .nextRun || lhs.enabled)
        let rightValid = right != .distantPast && (sort != .nextRun || rhs.enabled)
        if leftValid != rightValid { return leftValid }
        if leftValid && left != right { return sort == .nextRun ? left < right : left > right }
      }
      let order = lhs.title.localizedStandardCompare(rhs.title)
      return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
  }

  static func summary(_ tasks: [DesktopScheduledTask]) -> String {
    let enabled = tasks.filter(\.enabled).count
    let running = tasks.filter { ScheduledTaskFilter.running.includes($0) }.count
    let failed = tasks.filter { ScheduledTaskFilter.failed.includes($0) }.count
    return "启用 \(enabled) · 暂停 \(tasks.count - enabled) · 派发中 \(running) · 失败 \(failed)"
  }
}

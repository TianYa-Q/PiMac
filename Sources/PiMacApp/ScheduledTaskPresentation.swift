import Foundation

/// Pure list projection shared by the scheduler UI and regression tests.
enum ScheduledTaskFilter: String, CaseIterable, Identifiable {
  case all, enabled, paused, failed
  var id: Self { self }
  var title: String {
    switch self {
    case .all: return "全部"
    case .enabled: return "已启用"
    case .paused: return "已暂停"
    case .failed: return "派发失败"
    }
  }

  func includes(_ task: DesktopScheduledTask) -> Bool {
    switch self {
    case .all: return true
    case .enabled: return task.enabled
    case .paused: return !task.enabled
    case .failed: return task.raw["lastRunStatus"] as? String == "failed"
    }
  }
}

enum ScheduledTaskPresentation {
  static func visibleTasks(
    _ tasks: [DesktopScheduledTask], query: String, filter: ScheduledTaskFilter,
    projectTitles: [String: String] = [:]
  ) -> [DesktopScheduledTask] {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    return tasks.filter { task in
      guard filter.includes(task) else { return false }
      let selection = task.raw["modelSelection"] as? [String: Any] ?? [:]
      let text = [
        task.title, task.prompt, projectTitles[task.projectID] ?? "",
        selection["model"] as? String ?? "", task.raw["lastRunError"] as? String ?? "",
      ]
      .joined(separator: "\n")
      return terms.allSatisfy { text.localizedStandardContains($0) }
    }
  }
}

import Foundation

/// Bounded private read model. File reads never activate a session or start Pi.
@MainActor
struct T3WorkspaceReadModel {
  enum ReadError: Error { case tooLarge, staleTarget }
  static let catalogBudget = 512 * 1024
  static let detailBudget = 8 * 1024 * 1024

  enum ReadSource {
    case loaded([ChatEntry])
    case saved(path: String, project: String)
  }

  static func catalog(_ workspace: WorkspaceModel) throws -> [String: Any] {
    guard workspace.projects.count <= 128 else { throw ReadError.tooLarge }
    let drafts = Set(
      workspace.tabs.filter { $0.isDraft && !$0.model.hasUserMessage }
        .map { $0.model.currentSessionPath })
    var latestUserDates: [String: Date] = [:]
    for tab in workspace.tabs {
      if let date = tab.model.messages.last(where: { $0.kind == .user })?.timestamp {
        let path = tab.model.currentSessionPath
        latestUserDates[path] = max(latestUserDates[path] ?? .distantPast, date)
      }
    }
    var visiblePaths: Set<String> = []
    var count = 0
    var projects: [[String: Any]] = []
    for project in workspace.projects {
      let sessions = workspace.sessions(in: project.url).filter { !drafts.contains($0.path) }
      visiblePaths.formUnion(sessions.map(\.path))
      count += sessions.count
      guard count <= 2048 else { throw ReadError.tooLarge }
      projects.append([
        "path": project.id, "title": project.name,
        "sessions": sessions.map {
          [
            "path": $0.path, "title": $0.title,
            "updatedAt": iso(max($0.modifiedAt, latestUserDates[$0.path] ?? .distantPast)),
          ]
        },
      ])
    }
    let runtimes: [[String: Any]] = workspace.tabs.compactMap { tab in
      let model = tab.model
      guard let project = model.projectURL?.standardizedFileURL.path,
        workspace.projects.contains(where: { $0.id == project }),
        !model.currentSessionPath.isEmpty, visiblePaths.contains(model.currentSessionPath)
      else { return nil }
      return [
        "target": tab.id.uuidString, "projectPath": project, "path": model.currentSessionPath,
        "title": model.sessionName, "model": model.selectedModelId,
        "busy": model.isBusy, "connected": model.connectionState == .connected,
        "pendingInput": model.extensionUI?.hasPendingDialog(for: model) ?? false,
        "loaded": model.hasUserMessage && !model.isLoadingConfiguration,
      ]
    }
    guard runtimes.count <= 128 else { throw ReadError.tooLarge }
    return try bounded(["projects": projects, "runtimes": runtimes], budget: catalogBudget)
  }

  static func detail(
    _ workspace: WorkspaceModel, target: String?, sessionPath: String?, projectPath: String?
  ) throws -> [String: Any] {
    guard
      case .loaded(let messages) = try readSource(
        workspace, target: target, sessionPath: sessionPath, projectPath: projectPath)
    else { throw ReadError.staleTarget }
    return try transcript(messages)
  }

  static func readSource(
    _ workspace: WorkspaceModel, target: String?, sessionPath: String?, projectPath: String?
  ) throws -> ReadSource {
    guard let path = sessionPath, !path.isEmpty, let projectPath,
      let project = workspace.projects.first(where: { $0.id == projectPath }),
      workspace.sessions(in: project.url).contains(where: { $0.path == path }),
      !workspace.tabs.contains(where: {
        $0.model.currentSessionPath == path && $0.isDraft && !$0.model.hasUserMessage
      })
    else { throw ReadError.staleTarget }
    if let target {
      guard let id = UUID(uuidString: target),
        let tab = workspace.tabs.first(where: { $0.id == id }),
        tab.model.currentSessionPath == path,
        tab.model.projectURL?.standardizedFileURL.path == projectPath
      else { throw ReadError.staleTarget }
      if tab.model.hasUserMessage, !tab.model.isLoadingConfiguration {
        return .loaded(tab.model.messages)
      }
    }
    return .saved(path: path, project: projectPath)
  }

  static func transcript(_ messages: [ChatEntry]) throws -> [String: Any] {
    guard messages.count <= 20000 else { throw ReadError.tooLarge }
    var bytes = 0
    var entries: [[String: Any]] = []
    for entry in messages {
      bytes += entry.text.utf8.count + (entry.toolInput?.utf8.count ?? 0)
      guard bytes <= detailBudget else { throw ReadError.tooLarge }
      let kind: String
      switch entry.kind {
      case .user: kind = "user"
      case .assistant: kind = "assistant"
      case .thinking: kind = "reasoning"
      case .tool: kind = "tool"
      case .compaction: kind = "compaction"
      case .system: kind = "system"
      }
      entries.append([
        "id": entry.id, "kind": kind, "text": entry.text,
        "title": entry.title, "input": entry.toolInput ?? "",
        "running": entry.isRunning, "error": entry.isError,
        "createdAt": iso(entry.timestamp ?? Date(timeIntervalSince1970: 0)),
      ])
    }
    return try bounded(["entries": entries], budget: detailBudget)
  }

  private static func bounded(_ value: [String: Any], budget: Int) throws -> [String: Any] {
    guard try JSONSerialization.data(withJSONObject: value).count <= budget else {
      throw ReadError.tooLarge
    }
    return value
  }

  private static let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static func iso(_ date: Date) -> String { formatter.string(from: date) }
}

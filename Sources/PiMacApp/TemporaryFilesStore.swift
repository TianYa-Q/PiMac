import Combine
import Foundation

struct TemporaryCleanupRecord: Codable, Identifiable, Sendable {
  let id: UUID
  let date: Date
  let results: [TemporaryCleanupResult]
}

@MainActor
final class TemporaryFilesStore: ObservableObject {
  @Published var automaticCleanup: Bool {
    didSet { defaults?.set(automaticCleanup, forKey: "temporaryFiles.automaticCleanup") }
  }
  @Published private(set) var isRunning = false
  @Published private(set) var records: [TemporaryCleanupRecord] = []
  @Published private(set) var errorMessage = ""
  private let defaults: UserDefaults?
  private let cleaner: TemporaryFileCleaner
  private var task: Task<Void, Never>?
  private var nextAutomaticCheck = Date.distantPast

  init(defaults: UserDefaults?, cleaner: TemporaryFileCleaner = TemporaryFileCleaner()) {
    self.defaults = defaults
    self.cleaner = cleaner
    automaticCleanup = defaults?.object(forKey: "temporaryFiles.automaticCleanup") as? Bool ?? true
    if let data = defaults?.data(forKey: "temporaryFiles.history") {
      do {
        records = try JSONDecoder().decode([TemporaryCleanupRecord].self, from: data)
        if let last = records.first { nextAutomaticCheck = last.date.addingTimeInterval(3600) }
      } catch { errorMessage = "清理记录无法读取：\(error.localizedDescription)" }
    }
  }

  func run(
    workspaces: [TemporaryCleanupWorkspace], manually: Bool,
    protection: @escaping @Sendable (URL) async -> String?
  ) {
    guard !isRunning, !workspaces.isEmpty,
      manually || (automaticCleanup && Date() >= nextAutomaticCheck)
    else { return }
    isRunning = true
    errorMessage = ""
    nextAutomaticCheck = Date().addingTimeInterval(3600)
    task = Task { [weak self, cleaner] in
      let results = await cleaner.clean(workspaces, now: Date()) { [weak self] directory in
        if Task.isCancelled { return "整理已停止，剩余内容保留" }
        if !manually, await self?.automaticCleanup != true { return "自动清理已关闭" }
        return await protection(directory)
      }
      guard let self else { return }
      self.records.insert(TemporaryCleanupRecord(id: UUID(), date: Date(), results: results), at: 0)
      self.records = Array(self.records.prefix(20))
      do {
        let data = try JSONEncoder().encode(self.records)
        self.defaults?.set(data, forKey: "temporaryFiles.history")
      } catch { self.errorMessage = "清理完成，但记录保存失败：\(error.localizedDescription)" }
      self.isRunning = false
      self.task = nil
    }
  }

  func stopAndWait() async {
    task?.cancel()
    await task?.value
  }
}

extension WorkspaceModel {
  /// 项目根目录和 Server 已登记的 worktree 共用一套策略，不猜测其他磁盘目录。
  var temporaryCleanupWorkspaces: [TemporaryCleanupWorkspace] {
    var roots: [String: TemporaryCleanupWorkspace] = [:]
    for project in projects {
      let directory = project.url.standardizedFileURL.resolvingSymlinksInPath()
      roots[directory.path] = TemporaryCleanupWorkspace(name: project.name, directory: directory)
    }
    for thread in server.threads {
      guard let path = thread["worktreePath"] as? String, path.hasPrefix("/"),
        let projectID = thread["projectId"] as? String,
        let project = server.projects.first(where: { $0["id"] as? String == projectID }),
        let name = project["title"] as? String
      else { continue }
      let directory = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
      if roots[directory.path] == nil {
        roots[directory.path] = TemporaryCleanupWorkspace(
          name: "\(name) · \(directory.lastPathComponent)", directory: directory)
      }
    }
    return roots.values.sorted { $0.directory.path < $1.directory.path }
  }

  func maintainTemporaryFiles(manually: Bool = false) {
    // 缓存 shell 不足以授权文件操作；只有实时 Server 状态才能触发自动整理。
    guard server.isConnected else { return }
    temporaryFiles.run(workspaces: temporaryCleanupWorkspaces, manually: manually) {
      [weak self] directory in
      guard let self else { return "工作区已关闭" }
      return await self.temporaryCleanupProtection(directory)
    }
  }

  func temporaryCleanupProtection(_ directory: URL) -> String? {
    guard server.isConnected else { return "Server 未连接，暂不清理" }
    guard temporaryCleanupWorkspaces.contains(where: { $0.directory.path == directory.path }) else {
      return "工作区已移除，暂不清理"
    }
    if git.busy { return "Git 操作进行中，暂不清理" }
    if DevelopmentReloadState.editsPending(
      directory: directory.appendingPathComponent(".build/dev-edits", isDirectory: true))
    {
      return "存在未完成的编辑批次，暂不清理"
    }
    let projectIDs = Set(
      server.projects.compactMap { project -> String? in
        guard let path = project["workspaceRoot"] as? String else { return nil }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let belongs =
          root.path == directory.path
          || server.threads.contains {
            $0["projectId"] as? String == project["id"] as? String
              && ($0["worktreePath"] as? String).map {
                URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
                  == directory.path
              } == true
          }
        return belongs ? project["id"] as? String : nil
      })
    let idle = ["idle", "ready", "completed", "failed", "cancelled", "interrupted", "archived"]
    for thread in server.threads where projectIDs.contains(thread["projectId"] as? String ?? "") {
      let state = thread["status"] as? String ?? "unknown"
      let queued = thread["queuedMessages"] as? [[String: Any]] ?? []
      if !idle.contains(state) || !queued.isEmpty {
        return "项目有活跃任务或待处理消息，暂不清理"
      }
    }
    if tabs.contains(where: { tab in
      guard let url = tab.model.projectURL else { return false }
      return projectIDs.contains(server.projectID(for: url) ?? "") && !tab.model.canRestartSafely
    }) {
      return "桌面任务尚未完成，暂不清理"
    }
    return nil
  }
}

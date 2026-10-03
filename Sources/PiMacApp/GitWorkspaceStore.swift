import Combine
import Foundation

struct GitWorkspaceStatus: Equatable {
  struct File: Identifiable, Equatable {
    let path: String
    let insertions: Int
    let deletions: Int
    var id: String { path }
  }
  let isRepo: Bool
  let branch: String?
  let hasUpstream: Bool
  let ahead: Int
  let behind: Int
  let files: [File]

  init(_ json: [String: Any]) {
    isRepo = json["isRepo"] as? Bool ?? false
    branch = json["refName"] as? String
    hasUpstream = json["hasUpstream"] as? Bool ?? false
    ahead = json["aheadCount"] as? Int ?? 0
    behind = json["behindCount"] as? Int ?? 0
    let tree = json["workingTree"] as? [String: Any] ?? [:]
    files = (tree["files"] as? [[String: Any]] ?? []).compactMap {
      guard let path = $0["path"] as? String else { return nil }
      return File(path: path, insertions: $0["insertions"] as? Int ?? 0,
        deletions: $0["deletions"] as? Int ?? 0)
    }
  }
}

/// Presentation only. Git execution, hooks, credentials and worktrees belong to T3.
@MainActor
final class GitWorkspaceStore: ObservableObject {
  @Published private(set) var status: GitWorkspaceStatus?
  @Published private(set) var branches: [String] = []
  @Published private(set) var busy = false
  @Published private(set) var loading = false
  @Published private(set) var requiresRefresh = false
  @Published private(set) var message = ""
  @Published private(set) var progress = ""
  @Published private(set) var pullRequestURL: URL?
  @Published var selectedFiles: Set<String> = []
  private var cwd = ""
  private var refreshID = UUID()

  func refresh(client: T3DesktopClient, cwd: String) async {
    guard !busy else { return }
    let current = UUID()
    refreshID = current
    loading = true
    defer { if refreshID == current { loading = false } }
    if self.cwd != cwd {
      self.cwd = cwd
      status = nil
      branches = []
      selectedFiles = []
      pullRequestURL = nil
      message = ""
    }
    do {
      let snapshot = try await client.gitRPC("vcs.refreshStatus", payload: ["cwd": cwd])
      try Task.checkCancellation()
      let refs = try await client.gitRPC("vcs.listRefs", payload: ["cwd": cwd, "limit": 200, "refKind": "local"])
      try Task.checkCancellation()
      guard refreshID == current else { return }
      status = GitWorkspaceStatus(snapshot)
      branches = (refs["refs"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
      selectedFiles.formIntersection(Set(status?.files.map(\.path) ?? []))
      requiresRefresh = false
      message = (refs["nextCursor"] as? Int) != nil ? "仅显示前 200 个本地分支。" : ""
    } catch is CancellationError {
      return
    } catch {
      guard refreshID == current else { return }
      requiresRefresh = true
      message = "Git 状态读取失败，请检查 Server 连接后刷新。"
    }
  }

  static func actionPayload(cwd: String, action: String, message: String, files: Set<String>) -> [String: Any]? {
    guard ["commit", "push", "create_pr", "commit_push", "commit_push_pr"].contains(action) else { return nil }
    var payload: [String: Any] = ["cwd": cwd, "action": action, "actionId": UUID().uuidString]
    if action.contains("commit") {
      let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, text.count <= 10_000, !files.isEmpty else { return nil }
      payload["commitMessage"] = text
      payload["filePaths"] = files.sorted()
    }
    return payload
  }

  func perform(client: T3DesktopClient, method: String, payload: [String: Any], cwd: String) async {
    guard !busy, !loading, !requiresRefresh, self.cwd == cwd else { return }
    busy = true
    progress = "正在执行；请等待 Server 完成…"
    do {
      if method == "git.runStackedAction" {
        let result = try await client.gitAction(payload: payload) { [weak self] event in
          // Hook output may contain secrets; show only fixed progress categories.
          switch event["phase"] as? String {
          case "branch": self?.progress = "正在准备分支…"
          case "commit": self?.progress = "正在提交（包括 Git hooks）…"
          case "push": self?.progress = "正在推送…"
          case "pr": self?.progress = "正在创建 Pull Request…"
          default: break
          }
        }
        if let text = (result["pr"] as? [String: Any])?["url"] as? String,
          let url = URL(string: text), url.scheme == "https", url.host != nil,
          url.user == nil, url.password == nil { pullRequestURL = url }
      } else {
        _ = try await client.gitRPC(method, payload: payload)
      }
      busy = false
      await refresh(client: client, cwd: cwd)
      if !requiresRefresh { message = "Git 操作已完成。" }
    } catch {
      busy = false
      requiresRefresh = true
      message = "操作结果未确认，未自动重试。请先刷新并检查分支、提交或远端状态，再决定是否再次执行。"
    }
    progress = ""
  }
}

import Combine
import CoreFoundation
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

  enum InvalidSnapshot: Error { case malformed }

  /// Validate consumed fields before replacing authoritative state or unlocking mutations.
  static func validated(_ json: [String: Any]) throws -> GitWorkspaceStatus {
    guard let isRepo = boolean(json["isRepo"]) else { throw InvalidSnapshot.malformed }
    if !isRepo { return GitWorkspaceStatus(json) }
    guard json["refName"] is NSNull || (json["refName"] as? String)?.isEmpty == false,
      boolean(json["hasUpstream"]) != nil,
      nonnegativeInteger(json["aheadCount"]), nonnegativeInteger(json["behindCount"]),
      let tree = json["workingTree"] as? [String: Any],
      let files = tree["files"] as? [[String: Any]]
    else { throw InvalidSnapshot.malformed }
    var paths = Set<String>()
    for file in files {
      guard let path = file["path"] as? String, !path.isEmpty, !path.contains("\0"),
        paths.insert(path).inserted,
        nonnegativeInteger(file["insertions"]), nonnegativeInteger(file["deletions"])
      else { throw InvalidSnapshot.malformed }
    }
    return GitWorkspaceStatus(json)
  }

  private static func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      return nil
    }
    return number.boolValue
  }

  private static func nonnegativeInteger(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      let integer = value as? Int, integer >= 0
    else { return false }
    return number.doubleValue == Double(integer)
  }

  init(_ json: [String: Any]) {
    isRepo = json["isRepo"] as? Bool ?? false
    branch = json["refName"] as? String
    hasUpstream = json["hasUpstream"] as? Bool ?? false
    ahead = json["aheadCount"] as? Int ?? 0
    behind = json["behindCount"] as? Int ?? 0
    let tree = json["workingTree"] as? [String: Any] ?? [:]
    var seen = Set<String>()
    files = (tree["files"] as? [[String: Any]] ?? []).compactMap {
      guard let path = $0["path"] as? String, !path.isEmpty,
        seen.insert(path).inserted
      else { return nil }
      return File(
        path: path, insertions: $0["insertions"] as? Int ?? 0,
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
  @Published private(set) var refreshedAt: Date?
  /// Confirmation tokens expire on every refresh attempt, including failed refreshes.
  @Published private(set) var snapshotID = UUID()
  @Published var selectedFiles: Set<String> = []
  private var cwd = ""
  private var refreshID = UUID()

  func refresh(client: T3DesktopClient, cwd: String) async {
    await refresh(cwd: cwd) { method, payload in
      try await client.gitRPC(method, payload: payload)
    }
  }

  // Inject the transport so refresh races can be tested without a running Server.
  func refresh(cwd: String, rpc: (String, [String: Any]) async throws -> [String: Any]) async {
    await refreshSnapshot(cwd: cwd, rpc: rpc, reconcilingMutation: false)
  }

  private func refreshSnapshot(
    cwd: String, rpc: (String, [String: Any]) async throws -> [String: Any],
    reconcilingMutation: Bool
  ) async {
    guard !busy || reconcilingMutation else { return }
    let current = UUID()
    refreshID = current
    snapshotID = UUID()
    loading = true
    defer { if refreshID == current { loading = false } }
    if self.cwd != cwd {
      self.cwd = cwd
      status = nil
      branches = []
      selectedFiles = []
      pullRequestURL = nil
      refreshedAt = nil
      message = ""
      requiresRefresh = true
    }
    do {
      let snapshot = try await rpc("vcs.refreshStatus", ["cwd": cwd])
      try Task.checkCancellation()
      guard refreshID == current else { return }
      let nextStatus = try GitWorkspaceStatus.validated(snapshot)
      // Non-repositories have no refs; asking for them can turn a valid empty state into an error.
      let refs =
        nextStatus.isRepo
        ? try await rpc("vcs.listRefs", ["cwd": cwd, "limit": 200, "refKind": "local"])
        : [:]
      try Task.checkCancellation()
      guard refreshID == current else { return }
      let names: [String]
      if nextStatus.isRepo {
        guard let rawRefs = refs["refs"] as? [[String: Any]],
          rawRefs.allSatisfy({ ($0["name"] as? String)?.isEmpty == false })
        else { throw GitWorkspaceStatus.InvalidSnapshot.malformed }
        names = rawRefs.compactMap { $0["name"] as? String }
      } else {
        names = []
      }
      status = nextStatus
      branches = Array(Set(names)).sorted()
      refreshedAt = Date()
      selectedFiles.formIntersection(Set(status?.files.map(\.path) ?? []))
      requiresRefresh = false
      message = (refs["nextCursor"] as? Int) != nil ? "仅显示前 200 个本地分支。" : ""
    } catch is GitWorkspaceStatus.InvalidSnapshot {
      guard refreshID == current else { return }
      requiresRefresh = true
      message = "Server 返回了无效 Git 状态，已保留最近快照。请刷新后再执行操作。"
    } catch is CancellationError {
      guard refreshID == current else { return }
      requiresRefresh = true
      message = "Git 状态刷新已取消，请刷新后再执行操作。"
    } catch {
      guard refreshID == current else { return }
      requiresRefresh = true
      message = "Git 状态读取失败，请检查 Server 连接后刷新。"
    }
  }

  static func actionPayload(cwd: String, action: String, message: String, files: Set<String>)
    -> [String: Any]?
  {
    guard ["commit", "push", "create_pr", "commit_push", "commit_push_pr"].contains(action) else {
      return nil
    }
    var payload: [String: Any] = ["cwd": cwd, "action": action, "actionId": UUID().uuidString]
    if action.contains("commit") {
      let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, text.count <= 10_000, !files.isEmpty,
        files.allSatisfy(validFilePath)
      else { return nil }
      payload["commitMessage"] = text
      payload["filePaths"] = files.sorted()
    }
    return payload
  }

  private static func validFilePath(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
      && path.split(separator: "/", omittingEmptySubsequences: false)
        .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  @discardableResult
  func perform(
    client: T3DesktopClient, method: String, payload: [String: Any], cwd: String,
    expectedSnapshotID: UUID
  ) async -> Bool {
    await perform(
      method: method, payload: payload, cwd: cwd, expectedSnapshotID: expectedSnapshotID
    ) { method, payload in
      if method != "git.runStackedAction" {
        return try await client.gitRPC(method, payload: payload)
      }
      return try await client.gitAction(payload: payload) { [weak self] event in
        // Hook output may contain secrets; show only fixed progress categories.
        switch event["phase"] as? String {
        case "branch": self?.progress = "正在准备分支…"
        case "commit": self?.progress = "正在提交（包括 Git hooks）…"
        case "push": self?.progress = "正在推送…"
        case "pr": self?.progress = "正在创建 Pull Request…"
        default: break
        }
      }
    }
  }

  /// The same state machine serves the live transport and deterministic race tests.
  @discardableResult
  func perform(
    method: String, payload: [String: Any], cwd: String, expectedSnapshotID: UUID,
    rpc: (String, [String: Any]) async throws -> [String: Any]
  ) async -> Bool {
    guard !busy, !loading, !requiresRefresh, self.cwd == cwd, !Task.isCancelled,
      payload["cwd"] as? String == cwd, status?.isRepo == true
    else { return false }
    if expectedSnapshotID != snapshotID {
      message = "Git 状态在确认期间已刷新，操作未发送。请检查最新状态并重新确认。"
      return false
    }
    guard ["git.runStackedAction", "vcs.pull", "vcs.switchRef", "vcs.createRef"].contains(method)
    else { return false }
    if method == "git.runStackedAction" {
      guard let action = payload["action"] as? String,
        let validated = Self.actionPayload(
          cwd: cwd, action: action, message: payload["commitMessage"] as? String ?? "",
          files: Set(payload["filePaths"] as? [String] ?? [])),
        payload["actionId"] is String
      else { return false }
      if let files = validated["filePaths"] as? [String] {
        guard Set(files).isSubset(of: Set(status?.files.map(\.path) ?? [])) else {
          message = "所选文件已不在最新变更列表中，操作未发送。请重新选择。"
          return false
        }
      }
      if action.contains("pr") { pullRequestURL = nil }
    }
    busy = true
    progress = "正在执行；请等待 Server 完成…"
    defer {
      busy = false
      progress = ""
    }
    do {
      let result = try await rpc(method, payload)
      if method == "git.runStackedAction",
        let text = (result["pr"] as? [String: Any])?["url"] as? String,
        let url = URL(string: text), url.scheme == "https", url.host != nil,
        url.user == nil, url.password == nil
      {
        pullRequestURL = url
      }
      // Keep the mutation lease through reconciliation. A second operation or
      // workspace refresh must not interleave while its outcome is being read.
      await refreshSnapshot(cwd: cwd, rpc: rpc, reconcilingMutation: true)
      if !requiresRefresh { message = "Git 操作已完成。" }
      return !requiresRefresh
    } catch {
      requiresRefresh = true
      message = "操作结果未确认，未自动重试。请先刷新并检查分支、提交或远端状态，再决定是否再次执行。"
      return false
    }
  }
}

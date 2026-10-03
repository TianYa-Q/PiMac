import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct GitWorkspaceTests {
  @Test func selectedFilePayloadsNeverCommitTheWholeWorkspaceImplicitly() {
    #expect(GitWorkspaceStore.actionPayload(cwd: "/repo", action: "commit", message: "hi", files: []) == nil)
    #expect(GitWorkspaceStore.actionPayload(cwd: "/repo", action: "commit", message: "  ", files: ["a"]) == nil)
    #expect(GitWorkspaceStore.actionPayload(cwd: "/repo", action: "unknown", message: "hi", files: ["a"]) == nil)
    let payload = GitWorkspaceStore.actionPayload(cwd: "/repo", action: "commit_push", message: " fix ", files: ["b", "a"])
    #expect(payload?["filePaths"] as? [String] == ["a", "b"])
    #expect(payload?["commitMessage"] as? String == "fix")
    #expect(payload?["actionId"] is String)
    let push = GitWorkspaceStore.actionPayload(cwd: "/repo", action: "push", message: "", files: [])
    #expect(push != nil)
    #expect(push?["filePaths"] == nil)
  }

  @Test func statusRetainsDetachedHeadAndServerFileCounts() {
    let status = GitWorkspaceStatus(["isRepo": true, "refName": NSNull(), "hasUpstream": true,
      "aheadCount": 2, "behindCount": 1,
      "workingTree": ["files": [["path": "a.swift", "insertions": 3, "deletions": 4]]]])
    #expect(status.isRepo)
    #expect(status.branch == nil)
    #expect(status.ahead == 2 && status.behind == 1)
    #expect(status.files.first?.insertions == 3)
    #expect(status.files.first?.deletions == 4)
  }

  @Test(.timeLimit(.minutes(1)))
  func desktopGitStreamAndDiffReachNativeServerWithoutReplayingFailures() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ args: String...) throws -> String {
      let process = Process(), pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["-C", repo.path] + args
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)
      return String(decoding: data, as: UTF8.self)
    }
    _ = try git("init", "-b", "main")
    _ = try git("config", "user.name", "Fixture")
    _ = try git("config", "user.email", "fixture@example.test")
    try "before\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    _ = try git("add", ".")
    _ = try git("commit", "-m", "initial")
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = repository.appendingPathComponent("sidecars/t3-server/tests/fixtures/pi.mjs")
    let binary = root.appendingPathComponent("fixture-pi")
    try "#!/bin/sh\nexec node \"\(fixture.path)\" \"$@\"\n".write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "pimac-git-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(binary.path, forKey: "piPath")
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults)
    let client = T3DesktopClient(defaults: defaults)
    defer { client.stop(); service.stop(); workspace.disconnectAll() }
    try service.start(workspace: workspace, token: T3NetworkEndpoint.secret(), stateDirectory: root.appendingPathComponent("state"))
    client.start(service: service)
    try await client.waitUntilReady()
    _ = try await client.ensureProject(repo)
    let store = workspace.git
    await store.refresh(client: client, cwd: repo.path)
    #expect(store.status?.branch == "main")
    try "after\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try "keep\n".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
    _ = try git("add", "keep.txt")
    await store.refresh(client: client, cwd: repo.path)
    #expect(store.status?.files.contains(where: { $0.path == "file.txt" }) == true)
    let preview = try await client.gitRPC("review.getDiffPreview", payload: ["cwd": repo.path])
    let sources = preview["sources"] as? [[String: Any]] ?? []
    #expect(sources.contains { ($0["diff"] as? String)?.contains("+after") == true })
    let payload = try #require(GitWorkspaceStore.actionPayload(cwd: repo.path, action: "commit", message: "selected", files: ["file.txt"]))
    await store.perform(client: client, method: "git.runStackedAction", payload: payload, cwd: repo.path)
    #expect(!store.requiresRefresh)
    #expect(try git("show", "--pretty=", "--name-only", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines) == "file.txt")
    #expect(try git("status", "--porcelain").contains("keep.txt"))
    await store.perform(client: client, method: "vcs.switchRef", payload: ["cwd": repo.path, "refName": "missing"], cwd: repo.path)
    #expect(store.requiresRefresh)
    #expect(store.message.contains("未自动重试"))
    await store.perform(client: client, method: "vcs.createRef", payload: ["cwd": repo.path, "refName": "must-not-exist"], cwd: repo.path)
    #expect(!(try git("branch", "--list")).contains("must-not-exist"))
    await store.refresh(client: client, cwd: repo.path)
    #expect(!store.requiresRefresh)
    client.stop()
    await store.refresh(client: client, cwd: repo.path)
    #expect(store.requiresRefresh)
    #expect(store.status?.branch == "main") // Keep last known authoritative presentation.
  }
}

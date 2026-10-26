import Foundation
import Testing

@testable import PiMacApp

@Suite(.serialized)
struct TemporaryFileCleanupTests {
  private let manager = FileManager.default

  private func fixture() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/cleanup-tests-\(UUID().uuidString)")
    try manager.createDirectory(
      at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
    return root
  }

  private func dispose(_ root: URL) throws {
    if manager.fileExists(atPath: root.path) {
      try manager.trashItem(at: root, resultingItemURL: nil)
    }
  }

  private func cleaner(_ root: URL) -> TemporaryFileCleaner {
    TemporaryFileCleaner { file in
      let target = root.appendingPathComponent("recycled", isDirectory: true)
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      try FileManager.default.moveItem(
        at: file, to: target.appendingPathComponent(file.lastPathComponent))
    }
  }

  private func clean(_ root: URL, now: Date) async throws -> TemporaryCleanupResult {
    let results = await cleaner(root).clean(
      [TemporaryCleanupWorkspace(name: "Fixture", directory: root)], now: now,
      protection: { _ in nil })
    return try #require(results.first)
  }

  @Test func oldContentIsMovedButRecentContentRemains() async throws {
    let root = try fixture()
    defer { try? dispose(root) }
    let old = root.appendingPathComponent("tmp/old.ts")
    let fresh = root.appendingPathComponent("tmp/fresh.ts")
    try Data("old".utf8).write(to: old)
    try Data("fresh".utf8).write(to: fresh)
    let now = Date().addingTimeInterval(4 * 86400)
    try manager.setAttributes([.modificationDate: now], ofItemAtPath: fresh.path)
    let result = try await clean(root, now: now)
    #expect(result.errors.isEmpty)
    #expect(result.moved == 1)
    #expect(result.bytes == 3)
    #expect(!manager.fileExists(atPath: old.path))
    #expect(
      try Data(contentsOf: root.appendingPathComponent("recycled/old.ts")) == Data("old".utf8))
    #expect(manager.fileExists(atPath: fresh.path))
  }

  @Test func recentNestedContentAndRetentionMarkersProtectWholeTask() async throws {
    let root = try fixture()
    defer { try? dispose(root) }
    let now = Date().addingTimeInterval(4 * 86400)
    for (name, file) in [("recent", "recent.ts"), ("kept", ".keep"), ("locked", "worker.lock")] {
      let task = root.appendingPathComponent("tmp/\(name)")
      try manager.createDirectory(at: task, withIntermediateDirectories: true)
      let item = task.appendingPathComponent(file)
      try Data("protected".utf8).write(to: item)
      if name == "recent" {
        try manager.setAttributes([.modificationDate: now], ofItemAtPath: item.path)
      }
    }
    let result = try await clean(root, now: now)
    #expect(result.moved == 0)
    #expect(result.retained == 3)
    #expect(result.errors.isEmpty)
  }

  @Test func symlinkRootNeverTouchesOutsideFiles() async throws {
    let root = try fixture()
    defer { try? dispose(root) }
    let outside = root.appendingPathComponent("outside")
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("important".utf8).write(to: outside.appendingPathComponent("data"))
    try manager.trashItem(at: root.appendingPathComponent("tmp"), resultingItemURL: nil)
    try manager.createSymbolicLink(
      at: root.appendingPathComponent("tmp"), withDestinationURL: outside)
    let result = try await clean(root, now: Date().addingTimeInterval(4 * 86400))
    #expect(result.moved == 0)
    #expect(!result.errors.isEmpty)
    #expect(
      try String(contentsOf: outside.appendingPathComponent("data"), encoding: .utf8) == "important"
    )
  }

  @Test func gitTrackedFilesAreNotTemporaryGarbage() async throws {
    let root = try fixture()
    defer { try? dispose(root) }
    let file = root.appendingPathComponent("tmp/permanent-fixture.ts")
    try Data("tracked".utf8).write(to: file)
    for arguments in [
      ["init", "--quiet", root.path], ["-C", root.path, "add", "tmp/permanent-fixture.ts"],
    ] {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = arguments
      try process.run()
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)
    }
    let result = try await clean(root, now: Date().addingTimeInterval(4 * 86400))
    #expect(result.moved == 0)
    #expect(result.retained == 1)
    #expect(manager.fileExists(atPath: file.path))
  }

  @Test func runningProcessesKeepTheirWorkingDirectory() async throws {
    let root = try fixture()
    defer { try? dispose(root) }
    let directory = root.appendingPathComponent("tmp/active-task")
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    process.currentDirectoryURL = directory
    try process.run()
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }
    let result = try await clean(root, now: Date().addingTimeInterval(4 * 86400))
    #expect(result.errors.isEmpty)
    #expect(result.moved == 0)
    #expect(result.retained == 1)
    #expect(manager.fileExists(atPath: directory.path))
  }

  @Test func activeTaskProtectionStopsCleanupBeforeReadingContent() async throws {
    let root = try fixture()
    defer { try? dispose(root) }
    try Data("active".utf8).write(to: root.appendingPathComponent("tmp/active.ts"))
    let results = await cleaner(root).clean(
      [TemporaryCleanupWorkspace(name: "Active", directory: root)],
      now: Date().addingTimeInterval(4 * 86400), protection: { _ in "活跃任务" })
    #expect(results.first?.message == "活跃任务")
    #expect(results.first?.moved == 0)
    #expect(manager.fileExists(atPath: root.appendingPathComponent("tmp/active.ts").path))
  }

  @Test func failedMoveIsReportedInsteadOfSuccess() async throws {
    let root = try fixture()
    defer { try? dispose(root) }
    let file = root.appendingPathComponent("tmp/old.ts")
    try Data("old".utf8).write(to: file)
    let failing = TemporaryFileCleaner { file in
      try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("missing/old.ts"))
    }
    let results = await failing.clean(
      [TemporaryCleanupWorkspace(name: "Failure", directory: root)],
      now: Date().addingTimeInterval(4 * 86400), protection: { _ in nil })
    #expect(results.first?.moved == 0)
    #expect(results.first?.errors.isEmpty == false)
    #expect(manager.fileExists(atPath: file.path))
  }

  @MainActor @Test func storeDefaultsAndCorruptHistoryRemainObservable() throws {
    let suite = "cleanup-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TemporaryFilesStore(defaults: defaults)
    #expect(store.automaticCleanup)
    store.automaticCleanup = false
    #expect(!TemporaryFilesStore(defaults: defaults).automaticCleanup)
    defaults.set(Data("not json".utf8), forKey: "temporaryFiles.history")
    #expect(!TemporaryFilesStore(defaults: defaults).errorMessage.isEmpty)
  }

  @MainActor @Test func workspaceCatalogIncludesWorktreesAndProtectsDisconnectedServer() throws {
    let suite = "cleanup-shell-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = WorkspaceModel(
      restoreUserState: false, server: T3DesktopClient(defaults: defaults))
    defer { workspace.disconnectAll() }
    workspace.server.applyShell([
      "projects": [["id": "p", "title": "Project", "workspaceRoot": "/tmp/test-project"]],
      "threads": [
        ["id": "t", "projectId": "p", "status": "running", "worktreePath": "/tmp/worktree"]
      ],
    ])
    #expect(
      Set(workspace.temporaryCleanupWorkspaces.map(\.directory.path)) == [
        "/tmp/test-project", "/tmp/worktree",
      ])
    #expect(workspace.temporaryCleanupProtection(URL(fileURLWithPath: "/tmp/test-project")) != nil)
    #expect(!workspace.temporaryFiles.isRunning)
    workspace.server.didCompletePoll()
    #expect(
      workspace.temporaryCleanupProtection(URL(fileURLWithPath: "/tmp/test-project"))?
        .contains("活跃") == true)
  }

  @MainActor @Test func idleWorkspaceStillHonorsRealEditBatchBarrier() throws {
    let root = try fixture()
    defer { try? dispose(root) }
    let suite = "cleanup-barrier-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = WorkspaceModel(
      restoreUserState: false, server: T3DesktopClient(defaults: defaults))
    defer { workspace.disconnectAll() }
    workspace.server.applyShell([
      "projects": [["id": "p", "title": "Fixture", "workspaceRoot": root.path]],
      "threads": [["id": "t", "projectId": "p", "status": "completed"]],
    ])
    workspace.server.didCompletePoll()
    // 合成项目选择会进入桌面配置加载态；本用例单独验证空闲后的真实批次屏障。
    for tab in workspace.tabs { tab.model.isLoadingConfiguration = false }
    #expect(workspace.temporaryCleanupProtection(root) == nil)
    let barrier = root.appendingPathComponent(".build/dev-edits")
    try manager.createDirectory(at: barrier, withIntermediateDirectories: true)
    let token = barrier.appendingPathComponent("own-batch.json")
    try Data("{}".utf8).write(to: token)
    #expect(workspace.temporaryCleanupProtection(root)?.contains("编辑批次") == true)
    try manager.trashItem(at: token, resultingItemURL: nil)
    #expect(workspace.temporaryCleanupProtection(root) == nil)
  }

  @Test func defaultCleanerUsesSystemTrashForItsOwnExpiredFixture() async throws {
    let root = try fixture()
    defer { try? dispose(root) }
    let file = root.appendingPathComponent("tmp/expired-\(UUID().uuidString).ts")
    try Data("expired".utf8).write(to: file)
    let results = await TemporaryFileCleaner().clean(
      [TemporaryCleanupWorkspace(name: "System trash", directory: root)],
      now: Date().addingTimeInterval(4 * 86400), protection: { _ in nil })
    #expect(results.first?.errors.isEmpty == true)
    #expect(results.first?.moved == 1)
    #expect(!manager.fileExists(atPath: file.path))
  }

  @MainActor @Test func storeRunsOncePersistsHistoryAndHonorsAutomaticSwitch() async throws {
    let root = try fixture()
    defer { try? dispose(root) }
    let suite = "cleanup-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TemporaryFilesStore(defaults: defaults, cleaner: cleaner(root))
    let workspaces = [TemporaryCleanupWorkspace(name: "Fixture", directory: root)]
    store.automaticCleanup = false
    store.run(workspaces: workspaces, manually: false, protection: { _ in nil })
    #expect(!store.isRunning)
    store.run(workspaces: workspaces, manually: true, protection: { _ in nil })
    #expect(store.isRunning)
    store.run(workspaces: workspaces, manually: true, protection: { _ in nil })
    let deadline = Date().addingTimeInterval(10)
    while store.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!store.isRunning)
    #expect(store.records.count == 1)
    #expect(TemporaryFilesStore(defaults: defaults).records.count == 1)
    store.automaticCleanup = true
    store.run(workspaces: workspaces, manually: false, protection: { _ in nil })
    #expect(!store.isRunning)
    #expect(store.records.count == 1)
  }

  @Test func oversizedDirectoryDoesNotStarveLaterEntries() async throws {
    let root = try fixture()
    defer { try? dispose(root) }
    let large = root.appendingPathComponent("tmp/a-large")
    try manager.createDirectory(at: large, withIntermediateDirectories: true)
    for index in 0..<8 {
      try Data("old".utf8).write(to: large.appendingPathComponent("\(index).ts"))
    }
    let small = root.appendingPathComponent("tmp/z-small.ts")
    try Data("small".utf8).write(to: small)
    let limited = TemporaryFileCleaner(itemLimit: 4) { file in
      try FileManager.default.moveItem(
        at: file, to: root.appendingPathComponent(file.lastPathComponent))
    }
    let results = await limited.clean(
      [TemporaryCleanupWorkspace(name: "Limit", directory: root)],
      now: Date().addingTimeInterval(4 * 86400), protection: { _ in nil })
    let result = try #require(results.first)
    #expect(result.moved == 1)
    #expect(result.errors.contains { $0.contains("a-large") })
    #expect(result.completedAt == nil)
    #expect(manager.fileExists(atPath: large.path))
    #expect(!manager.fileExists(atPath: small.path))
  }

  @Test func nextPassResumesAfterWorkspaceBudgetIsExhausted() async throws {
    let root = try fixture()
    defer { try? dispose(root) }
    let limited = TemporaryFileCleaner(scanBudget: 1) { file in
      try FileManager.default.moveItem(
        at: file, to: root.appendingPathComponent(file.lastPathComponent))
      Thread.sleep(forTimeInterval: 1)
    }
    for name in ["a.ts", "b.ts"] {
      try Data("old".utf8).write(to: root.appendingPathComponent("tmp/\(name)"))
    }
    let workspaces = [TemporaryCleanupWorkspace(name: "Resume", directory: root)]
    let now = Date().addingTimeInterval(4 * 86400)
    let first = await limited.clean(workspaces, now: now, protection: { _ in nil })
    #expect(first.first?.moved == 1)
    #expect(first.first?.completedAt == nil)
    // 重新放回排在最前的旧项；下一轮必须从 b 开始，而非反复扫描 a。
    try manager.moveItem(
      at: root.appendingPathComponent("a.ts"), to: root.appendingPathComponent("tmp/a.ts"))
    let second = await limited.clean(workspaces, now: now, protection: { _ in nil })
    #expect(second.first?.items == ["b.ts"])
    #expect(manager.fileExists(atPath: root.appendingPathComponent("tmp/a.ts").path))
  }

  @Test func directKeepMarkerAvoidsScanningLargeSubtree() async throws {
    let root = try fixture()
    defer { try? dispose(root) }
    let task = root.appendingPathComponent("tmp/kept")
    try manager.createDirectory(at: task, withIntermediateDirectories: true)
    try Data().write(to: task.appendingPathComponent(".keep"))
    for index in 0..<8 {
      try Data("old".utf8).write(to: task.appendingPathComponent("\(index).ts"))
    }
    let results = await TemporaryFileCleaner(itemLimit: 1).clean(
      [TemporaryCleanupWorkspace(name: "Keep", directory: root)],
      now: Date().addingTimeInterval(4 * 86400), protection: { _ in nil })
    #expect(results.first?.moved == 0)
    #expect(results.first?.retained == 1)
    #expect(results.first?.errors.isEmpty == true)
    #expect(results.first?.completedAt != nil)
  }

  @MainActor @Test func automaticCleanupWaitsADayEvenAfterIncompleteCheck() async throws {
    let root = try fixture()
    defer { try? dispose(root) }
    for (complete, age) in [
      (false, 86_300.0), (true, 86_300.0), (false, 86_500.0), (true, 86_500.0),
    ] {
      let suite = "cleanup-daily-\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let date = Date().addingTimeInterval(-age)
      let due = age >= 86_400
      var result = TemporaryCleanupResult(name: "Fixture", path: root.path)
      result.completedAt = complete ? date : nil
      defaults.set(
        try JSONEncoder().encode([
          TemporaryCleanupRecord(id: UUID(), date: date, results: [result])
        ]), forKey: "temporaryFiles.history")
      let store = TemporaryFilesStore(defaults: defaults, cleaner: cleaner(root))
      store.run(
        workspaces: [TemporaryCleanupWorkspace(name: "Fixture", directory: root)],
        manually: false, protection: { _ in nil })
      #expect(store.isRunning == due)
      let deadline = Date().addingTimeInterval(10)
      while store.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
      #expect(!store.isRunning)
      #expect(store.records.count == (due ? 2 : 1))
    }
  }

  @Test func directorySwappedAtFinalGateCannotEscapeTmp() async throws {
    let root = try fixture()
    defer { try? dispose(root) }
    let outside = root.appendingPathComponent("outside")
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("protected".utf8).write(to: outside.appendingPathComponent("old.ts"))
    try Data("expired".utf8).write(to: root.appendingPathComponent("tmp/old.ts"))
    let swap = CleanupTestDirectorySwap(root: root)
    let results = await cleaner(root).clean(
      [TemporaryCleanupWorkspace(name: "Swap", directory: root)],
      now: Date().addingTimeInterval(4 * 86400),
      protection: { _ in await swap.protection() })
    #expect(results.first?.moved == 0)
    #expect(results.first?.errors.isEmpty == false)
    #expect(
      try String(contentsOf: outside.appendingPathComponent("old.ts"), encoding: .utf8)
        == "protected")
  }

  @Test func taskStartingImmediatelyBeforeMovePreventsCleanup() async throws {
    let root = try fixture()
    defer { try? dispose(root) }
    let file = root.appendingPathComponent("tmp/old.ts")
    try Data("old".utf8).write(to: file)
    let activity = CleanupTestActivity()
    let results = await cleaner(root).clean(
      [TemporaryCleanupWorkspace(name: "Race", directory: root)],
      now: Date().addingTimeInterval(4 * 86400),
      protection: { _ in await activity.protection() })
    #expect(results.first?.message == "任务刚刚启动")
    #expect(results.first?.moved == 0)
    #expect(manager.fileExists(atPath: file.path))
  }
}

private actor CleanupTestDirectorySwap {
  let root: URL
  private var calls = 0
  init(root: URL) { self.root = root }
  func protection() -> String? {
    calls += 1
    if calls == 3 {
      do {
        let manager = FileManager.default
        try manager.moveItem(
          at: root.appendingPathComponent("tmp"), to: root.appendingPathComponent("displaced-tmp"))
        try manager.createSymbolicLink(
          at: root.appendingPathComponent("tmp"),
          withDestinationURL: root.appendingPathComponent("outside"))
      } catch { return "目录切换失败" }
    }
    return nil
  }
}

private actor CleanupTestActivity {
  private var calls = 0
  func protection() -> String? {
    calls += 1
    return calls >= 3 ? "任务刚刚启动" : nil
  }
}

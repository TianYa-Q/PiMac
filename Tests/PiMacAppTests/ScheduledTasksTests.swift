import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ScheduledTasksTests {
  private func row(id: String = "task", enabled: Bool = true) -> [String: Any] {
    [
      "id": id, "title": "Daily", "prompt": "review", "enabled": enabled,
      "projectId": "project", "threadId": "thread",
      "schedule": ["type": "fixed_time", "timeOfDay": "09:00", "weekdays": [1, 3, 5]],
      "modelSelection": [
        "instanceId": "pi", "model": "test/model",
        "options": [["id": "thinking", "value": "high"]],
      ],
      "workspaceStrategy": [
        "type": "existing_worktree", "worktreePath": "/tmp/tree", "branch": "feature",
      ],
      "runtimeMode": "approval-required", "interactionMode": "plan",
      "createdBy": "agent", "creationSource": "mcp", "lastRunStatus": "never", "runCount": 0,
    ]
  }

  @Test func editingPreservesServerPoliciesAndRejectsDeletedTaskRecreation() throws {
    let task = try DesktopScheduledTask(row())
    var draft = ScheduledTaskDraft(task: task)
    #expect(draft.weekdays == [1, 3, 5])
    draft.title = "Updated"
    let payload = try draft.payload()
    #expect(payload["requireExisting"] as? Bool == true)
    #expect(payload["id"] as? String == "task")
    #expect(payload["threadId"] as? String == "thread")
    #expect(payload["runtimeMode"] as? String == "approval-required")
    #expect(payload["interactionMode"] as? String == "plan")
    #expect(payload["createdBy"] as? String == "agent")
    #expect(
      (payload["workspaceStrategy"] as? [String: Any])?["worktreePath"] as? String == "/tmp/tree")
    #expect(
      ((payload["modelSelection"] as? [String: Any])?["options"] as? [[String: Any]])?.count == 1)
    draft.modelID = "test/other"
    #expect((try draft.payload()["modelSelection"] as? [String: Any])?["options"] == nil)
  }

  @Test func newDraftHasStableIdentityAndValidatesSchedules() throws {
    var draft = ScheduledTaskDraft(projectID: "project", modelID: "test/model")
    draft.title = " task "
    draft.prompt = " prompt "
    #expect(draft.validationMessage == nil)
    let first = try draft.payload()
    let second = try draft.payload()
    #expect(first["id"] as? String == second["id"] as? String)
    #expect(first["commandId"] as? String == second["commandId"] as? String)
    #expect(first["requireExisting"] == nil)
    #expect(first["threadId"] is NSNull)
    #expect(first["title"] as? String == "task")
    for value in ["0", "0.99", "-1", "NaN", "inf", "1e100", "abc"] {
      draft.intervalMinutes = value
      #expect(draft.validationMessage != nil)
    }
    draft.intervalMinutes = "1.5"
    #expect((try draft.payload()["schedule"] as? [String: Any])?["everyMs"] as? Int == 90000)
    draft.scheduleType = "fixed_time"
    for value in ["24:00", "09:60", "9:5", "bad"] {
      draft.timeOfDay = value
      #expect(draft.validationMessage != nil)
    }
    draft.timeOfDay = "09:30"
    draft.weekdays = []
    #expect(draft.validationMessage != nil)
    draft.weekdays = [5, 1]
    #expect((try draft.payload()["schedule"] as? [String: Any])?["weekdays"] as? [Int] == [1, 5])
  }

  @Test func storeUsesNarrowMutationsAndNeverRetriesUnknownOutcomes() async throws {
    var calls: [(String, [String: Any])] = []
    var rows = [row()]
    var fail = false
    let store = ScheduledTasksStore { method, payload in
      calls.append((method, payload))
      if fail { throw URLError(.timedOut) }
      switch method {
      case "scheduledTasks.list": return ["tasks": rows]
      case "scheduledTasks.setEnabled":
        rows[0]["enabled"] = payload["enabled"]
        return ["task": rows[0]]
      case "scheduledTasks.delete":
        rows = []
        return ["id": payload["id"]!]
      default: return ["task": rows[0]]
      }
    }
    await store.refresh()
    #expect(store.hasLoaded)
    let task = try #require(store.tasks.first)
    await store.setEnabled(task)
    #expect(calls[1].0 == "scheduledTasks.setEnabled")
    #expect(calls[1].1.count == 2)
    #expect(store.tasks[0].enabled == false)
    fail = true
    let before = calls.count
    await store.runNow(task)
    #expect(calls.count == before + 1)
    #expect(store.errorMessage?.contains("不会自动重试") == true)
    #expect(!store.isMutating)
    await store.refresh()
    // Never replace authoritative rows with an optimistic empty list.
    #expect(store.tasks.count == 1)
    fail = false
    await store.refresh()
    #expect(store.errorMessage == nil)
    await store.delete(task)
    #expect(store.tasks.isEmpty)
  }

  @Test func unknownOutcomeBlocksAllMutationsUntilSuccessfulRefresh() async throws {
    var calls: [String] = []
    var failMutation = true
    var refreshFailure = 0
    let store = ScheduledTasksStore { method, _ in
      calls.append(method)
      if method == "scheduledTasks.list" {
        switch refreshFailure {
        case 1: throw URLError(.timedOut)
        case 2: return ["tasks": [["id": "bad"]]]
        case 3: throw CancellationError()
        default: return ["tasks": [row()]]
        }
      }
      if failMutation { throw URLError(.timedOut) }
      return ["task": row()]
    }
    await store.refresh()
    let task = try #require(store.tasks.first)
    let draft = ScheduledTaskDraft(task: task)
    await store.runNow(task)
    #expect(store.errorMessage?.contains("不会自动重试") == true)
    failMutation = false

    // Each unsuccessful refresh must retain the barrier and last known rows.
    for failure in 0...3 {
      if failure != 0 {
        refreshFailure = failure
        await store.refresh()
      }
      let before = calls.count
      await store.runNow(task)
      await store.setEnabled(task)
      await store.delete(task)
      #expect(await store.save(draft) == false)
      #expect(calls.count == before)
      #expect(store.errorMessage != nil)
      #expect(store.tasks.count == 1)
      #expect(!store.isMutating)
    }

    refreshFailure = 0
    await store.refresh()
    #expect(store.errorMessage == nil)
    let before = calls.count
    await store.runNow(task)
    #expect(Array(calls.dropFirst(before)) == ["scheduledTasks.runNow", "scheduledTasks.list"])
  }

  @Test func malformedRefreshDoesNotDiscardTheLastKnownList() async throws {
    var malformed = false
    let store = ScheduledTasksStore { _, _ in ["tasks": malformed ? [["id": "bad"]] : [row()]] }
    await store.refresh()
    malformed = true
    await store.refresh()
    #expect(store.tasks.count == 1)
    #expect(store.errorMessage != nil)
  }

  @Test func acceptedMutationWithFailedRefreshIsNotReportedAsUnconfirmed() async throws {
    var calls = 0
    let store = ScheduledTasksStore { method, _ in
      calls += 1
      if method == "scheduledTasks.list" { throw URLError(.timedOut) }
      return ["task": row()]
    }
    var draft = ScheduledTaskDraft(projectID: "project", modelID: "test/model")
    draft.title = "Task"
    draft.prompt = "Prompt"
    #expect(await store.save(draft))
    #expect(calls == 2)
    #expect(store.errorMessage?.contains("已被 Server 接受") == true)
    #expect(!store.isMutating)
  }

  @Test func concurrentClicksCannotDispatchDuplicateMutations() async throws {
    var mutations = 0
    let store = ScheduledTasksStore { method, _ in
      if method != "scheduledTasks.list" {
        mutations += 1
        try await Task.sleep(for: .milliseconds(50))
      }
      return ["tasks": [row()]]
    }
    let task = try DesktopScheduledTask(row())
    let first = Task { await store.runNow(task) }
    for _ in 0..<100 where !store.isMutating { await Task.yield() }
    #expect(store.isMutating)
    await store.runNow(task)
    await store.delete(task)
    await store.refresh()
    await first.value
    #expect(mutations == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func desktopSchedulerRPCsReachTheOfficialServerAndPi() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = repository.appendingPathComponent("sidecars/t3-server/tests/fixtures/pi.mjs")
    let binary = root.appendingPathComponent("fixture-pi")
    try "#!/bin/sh\nexec node \"\(fixture.path)\" \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "pimac-scheduler-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(binary.path, forKey: "piPath")
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults)
    let client = T3DesktopClient(defaults: defaults)
    defer {
      client.stop()
      service.stop()
      workspace.disconnectAll()
    }
    try service.start(
      workspace: workspace, token: T3NetworkEndpoint.secret(),
      stateDirectory: root.appendingPathComponent("state"))
    client.start(service: service)
    try await client.waitUntilReady()
    let projectID = try await client.ensureProject(root)
    var draft = ScheduledTaskDraft(projectID: projectID, modelID: "test/model")
    draft.title = "Desktop schedule"
    draft.prompt = "desktop scheduled fixture"
    draft.enabled = false
    let store = ScheduledTasksStore { method, payload in
      try await client.scheduledTasksRPC(method, payload: payload)
    }
    #expect(await store.save(draft))
    let task = try #require(store.tasks.first)
    await store.setEnabled(task)
    #expect(store.tasks.first?.enabled == true)
    #expect(store.tasks.first?.raw["nextRunAt"] is String)
    await store.setEnabled(try #require(store.tasks.first))
    await store.runNow(try #require(store.tasks.first))
    #expect(store.errorMessage == nil)
    #expect(store.tasks.first?.raw["lastRunStatus"] as? String == "succeeded")
    #expect(store.tasks.first?.raw["runCount"] as? Int == 1)
    var completed = false
    for _ in 0..<200 {
      try await client.refresh()
      if let thread = client.threads.first(where: { $0["title"] as? String == draft.title }),
        let id = thread["id"] as? String
      {
        let detail = try await client.request("/api/orchestration/threads/\(id)")
        let projection = detail["projection"] as? [String: Any]
        let items = projection?["visibleTurnItems"] as? [[String: Any]] ?? []
        if items.contains(where: {
          ($0["item"] as? [String: Any])?["text"] as? String == "Reply: desktop scheduled fixture"
        }) {
          completed = true
          break
        }
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(completed)
    let currentTask = try #require(store.tasks.first)
    var edit = ScheduledTaskDraft(task: currentTask)
    edit.title = "Edited desktop schedule"
    #expect(await store.save(edit))
    #expect(store.tasks.first?.title == edit.title)
    await store.delete(try #require(store.tasks.first))
    #expect(store.tasks.isEmpty)
  }
}

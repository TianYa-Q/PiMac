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

  @Test func cancelledNewTaskNeverDispatchesEvenWhenTransportIgnoresCancellation() async {
    var calls: [String] = []
    let store = ScheduledTasksStore { method, _ in
      calls.append(method)
      return ["tasks": []]
    }
    var draft = ScheduledTaskDraft(projectID: "project", modelID: "test/model")
    draft.title = "Task"
    draft.prompt = "Prompt"
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await store.refresh()
      return await store.save(draft)
    }
    #expect(await cancelled.value == false)
    #expect(calls.isEmpty)
    #expect(!store.requiresRefresh)
    #expect(!store.isMutating)
  }

  @Test func cancellationDuringReadOnlyPreflightDoesNotCreateAnUnknownOutcome() async throws {
    var cancelPreflight = false
    var mutations = 0
    let store = ScheduledTasksStore { method, _ in
      if method == "scheduledTasks.list" {
        if cancelPreflight {
          withUnsafeCurrentTask { $0?.cancel() }
        }
        return ["tasks": [row()]]
      }
      mutations += 1
      return [:]
    }
    await store.refresh()
    let original = try #require(store.tasks.first)
    cancelPreflight = true
    let operation = Task { await store.delete(original) }
    await operation.value
    #expect(mutations == 0)
    #expect(!store.requiresRefresh)
    #expect(store.errorMessage == nil)
    #expect(!store.isMutating)
  }

  @Test func cancellationAfterDispatchRetainsTheRefreshBarrier() async throws {
    let store = ScheduledTasksStore { method, _ in
      if method == "scheduledTasks.list" { return ["tasks": [row()]] }
      throw CancellationError()
    }
    await store.refresh()
    await store.delete(try #require(store.tasks.first))
    #expect(store.requiresRefresh)
    #expect(store.errorMessage?.contains("可能已生效") == true)
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
    for value in ["0", "0.99", "-1", "NaN", "inf", "1e100", "abc", "150119987580"] {
      draft.intervalMinutes = value
      #expect(draft.validationMessage != nil)
    }
    draft.intervalMinutes = "1.5"
    #expect((try draft.payload()["schedule"] as? [String: Any])?["everyMs"] as? Int == 90000)
    draft.scheduleType = "fixed_time"
    for value in ["24:00", "09:60", "9:5", "09:00\n", "０９:００", "bad"] {
      draft.timeOfDay = value
      #expect(draft.validationMessage != nil)
    }
    draft.timeOfDay = "9:05"
    #expect(draft.validationMessage == nil)
    draft.timeOfDay = "09:30"
    draft.weekdays = []
    #expect(draft.validationMessage != nil)
    draft.weekdays = [5, 1]
    #expect((try draft.payload()["schedule"] as? [String: Any])?["weekdays"] as? [Int] == [1, 5])
  }

  @Test func fractionalIntervalLabelsRetainPrecision() throws {
    var raw = row()
    raw["schedule"] = ["type": "interval", "everyMs": 90000]
    let task = try DesktopScheduledTask(raw)
    let minutes = 1.5.formatted(.number.precision(.fractionLength(0...3)))
    #expect(task.scheduleLabel == "每 \(minutes) 分钟")
    var draft = ScheduledTaskDraft(task: task)
    #expect(draft.intervalMinutes == "1.5")
    #expect((try draft.payload()["schedule"] as? [String: Any])?["everyMs"] as? Int == 90000)
    draft.modelInstanceID = "custom-provider"
    let selection = try #require(try draft.payload()["modelSelection"] as? [String: Any])
    #expect(selection["instanceId"] as? String == "custom-provider")
    #expect(selection["options"] == nil)
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
    #expect(calls[2].0 == "scheduledTasks.setEnabled")
    #expect(calls[2].1.count == 2)
    #expect(store.tasks[0].enabled == false)
    let pausedTask = try #require(store.tasks.first)
    fail = true
    let before = calls.count
    await store.runNow(pausedTask)
    #expect(calls.count == before + 1)
    #expect(store.errorMessage?.contains("未发送修改") == true)
    #expect(!store.isMutating)
    await store.refresh()
    // Never replace authoritative rows with an optimistic empty list.
    #expect(store.tasks.count == 1)
    fail = false
    await store.refresh()
    #expect(store.errorMessage == nil)
    await store.delete(try #require(store.tasks.first))
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
    #expect(
      Array(calls.dropFirst(before)) == [
        "scheduledTasks.list", "scheduledTasks.runNow", "scheduledTasks.list",
      ])
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
    await store.refresh()
    let task = try #require(store.tasks.first)
    let first = Task { await store.runNow(task) }
    for _ in 0..<100 where !store.isMutating { await Task.yield() }
    #expect(store.isMutating)
    await store.runNow(task)
    await store.delete(task)
    await store.refresh()
    await first.value
    #expect(mutations == 1)
  }

  @Test func preflightKeepsMutationLockWhileTheReadIsSuspended() async throws {
    var pauseNextRead = false
    var calls: [String] = []
    let store = ScheduledTasksStore { method, _ in
      calls.append(method)
      if pauseNextRead && method == "scheduledTasks.list" {
        pauseNextRead = false
        try await Task.sleep(for: .milliseconds(50))
      }
      return ["tasks": [row()]]
    }
    await store.refresh()
    calls = []
    pauseNextRead = true
    let task = try #require(store.tasks.first)
    let first = Task { await store.runNow(task) }
    for _ in 0..<100 where !store.isMutating { await Task.yield() }
    #expect(store.isMutating)
    await store.runNow(task)
    await store.delete(task)
    await store.refresh()
    #expect(await store.save(ScheduledTaskDraft(task: task)) == false)
    await first.value
    #expect(calls == ["scheduledTasks.list", "scheduledTasks.runNow", "scheduledTasks.list"])
    #expect(!store.isMutating)
  }

  @Test func validationErrorDoesNotBlockCorrectedDraft() async throws {
    var calls = 0
    let store = ScheduledTasksStore { _, _ in
      calls += 1
      return ["tasks": [row()]]
    }
    var draft = ScheduledTaskDraft(projectID: "project", modelID: "test/model")
    #expect(await store.save(draft) == false)
    #expect(store.errorMessage != nil)
    #expect(!store.requiresRefresh)
    #expect(calls == 0)
    draft.title = "Valid"
    draft.prompt = "Review"
    #expect(await store.save(draft))
    #expect(store.errorMessage == nil)
    #expect(store.lastRefreshedAt != nil)
    #expect(calls == 2)
  }

  @Test func duplicateAndEmptyIDsDoNotReplaceAuthoritativeRows() async throws {
    var rows = [row()]
    let store = ScheduledTasksStore { _, _ in ["tasks": rows] }
    await store.refresh()
    let refreshedAt = store.lastRefreshedAt
    rows = [row(), row()]
    await store.refresh()
    #expect(store.tasks.count == 1)
    #expect(store.requiresRefresh)
    #expect(store.lastRefreshedAt == refreshedAt)
    rows = [row(id: "")]
    await store.refresh()
    #expect(store.tasks.first?.id == "task")
    #expect(store.requiresRefresh)
    rows = [row(id: "recovered")]
    await store.refresh()
    #expect(!store.requiresRefresh)
    #expect(store.tasks.first?.id == "recovered")
  }

  @Test func copiedTaskIsPausedAndDoesNotReuseExecutionIdentityOrBinding() throws {
    let task = try DesktopScheduledTask(row())
    let first = ScheduledTaskDraft(copying: task)
    let second = ScheduledTaskDraft(copying: task)
    #expect(first.id != task.id)
    #expect(first.id != second.id)
    #expect(first.original == nil)
    #expect(!first.enabled)
    #expect(first.prompt == task.prompt)
    #expect(first.weekdays == [1, 3, 5])
    let payload = try first.payload()
    #expect(payload["requireExisting"] == nil)
    #expect(payload["threadId"] is NSNull)
    #expect((payload["workspaceStrategy"] as? [String: Any])?["type"] as? String == "root")
    #expect(payload["runtimeMode"] as? String == "approval-required")
    #expect(payload["createdBy"] as? String == "user")
    #expect((payload["modelSelection"] as? [String: Any])?["options"] == nil)
  }

  @Test func searchMatchesAllTermsAndCombinesWithStateFilters() throws {
    let first = try DesktopScheduledTask(row(id: "one"))
    var other = row(id: "two", enabled: false)
    other["title"] = "Nightly"
    other["lastRunStatus"] = "failed"
    other["lastRunError"] = "Connection lost"
    let second = try DesktopScheduledTask(other)
    let tasks = [first, second]
    #expect(
      ScheduledTaskPresentation.visibleTasks(tasks, query: "DAILY review", filter: .all).map(\.id)
        == ["one"])
    #expect(
      ScheduledTaskPresentation.visibleTasks(tasks, query: "", filter: .paused).map(\.id) == ["two"]
    )
    #expect(
      ScheduledTaskPresentation.visibleTasks(tasks, query: "connection", filter: .failed).map(\.id)
        == ["two"])
    #expect(
      ScheduledTaskPresentation.visibleTasks(tasks, query: "Nightly", filter: .enabled).isEmpty)
    #expect(
      ScheduledTaskPresentation.visibleTasks(
        tasks, query: "PiMac test/model", filter: .all, projectTitles: ["project": "PiMac"]
      ).count == 2)
  }

  @Test func obsoleteReviewsAndEditorsNeverDispatchMutations() async throws {
    for action in ["edit", "delete", "enable", "run"] {
      var rows = [row()]
      var mutations = 0
      let store = ScheduledTasksStore { method, _ in
        if method != "scheduledTasks.list" { mutations += 1 }
        return ["tasks": rows]
      }
      await store.refresh()
      let original = try #require(store.tasks.first)
      rows[0]["prompt"] = "changed by another client"
      // No UI refresh: the action itself must fetch authoritative state.
      switch action {
      case "edit": #expect(await store.save(ScheduledTaskDraft(task: original)) == false)
      case "delete": await store.delete(original)
      case "enable": await store.setEnabled(original)
      default: await store.runNow(original)
      }
      #expect(mutations == 0)
      #expect(store.requiresRefresh)
      #expect(store.errorMessage?.contains("已变更") == true)
      await store.refresh()
      await store.delete(try #require(store.tasks.first))
      #expect(mutations == 1)
    }
  }

  @Test func telemetryDoesNotExpireConfigurationButRunningTaskCannotRunAgain() async throws {
    var rows = [row()]
    var mutations = 0
    let store = ScheduledTasksStore { method, _ in
      if method != "scheduledTasks.list" { mutations += 1 }
      return ["tasks": rows]
    }
    await store.refresh()
    let original = try #require(store.tasks.first)
    rows[0]["runCount"] = 2
    rows[0]["lastRunStatus"] = "running"
    rows[0]["nextRunAt"] = "2026-06-01T10:00:00Z"
    await store.refresh()
    #expect(original.hasSameConfiguration(as: try #require(store.tasks.first)))
    await store.runNow(original)
    #expect(mutations == 0)
    #expect(!store.requiresRefresh)
    rows[0]["lastRunStatus"] = "succeeded"
    await store.refresh()
    await store.runNow(original)
    #expect(mutations == 1)
    rows = []
    await store.refresh()
    await store.delete(original)
    #expect(mutations == 1)
    #expect(store.requiresRefresh)
  }

  @Test func sortingIsStableAndMissingOrPausedSchedulesGoLast() throws {
    var one = row(id: "one")
    one["title"] = "Same"
    one["nextRunAt"] = "2026-06-01T10:00:00Z"
    one["lastRunAt"] = "2026-05-01T10:00:00Z"
    var two = row(id: "two")
    two["title"] = "Same"
    two["nextRunAt"] = "2026-06-01T09:00:00.000Z"
    two["lastRunAt"] = "2026-05-02T10:00:00Z"
    two["lastRunStatus"] = "running"
    var paused = row(id: "paused", enabled: false)
    paused["nextRunAt"] = "2020-01-01T00:00:00Z"
    var invalid = row(id: "invalid")
    invalid["nextRunAt"] = "not-a-date"
    let tasks = try [two, paused, invalid, one].map(DesktopScheduledTask.init)
    let next = ScheduledTaskPresentation.visibleTasks(
      tasks, query: "", filter: .all, sort: .nextRun)
    #expect(next.map(\.id) == ["two", "one", "invalid", "paused"])
    let recent = ScheduledTaskPresentation.visibleTasks(
      tasks, query: "", filter: .all, sort: .lastRun)
    #expect(Array(recent.prefix(2)).map(\.id) == ["two", "one"])
    #expect(
      ScheduledTaskPresentation.visibleTasks(tasks, query: "", filter: .running).map(\.id) == [
        "two"
      ])
    #expect(ScheduledTaskPresentation.summary(tasks) == "启用 3 · 暂停 1 · 派发中 1 · 失败 0")
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
    // Transport fixtures stay loopback-only.
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
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

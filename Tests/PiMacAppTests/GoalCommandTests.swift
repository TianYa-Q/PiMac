import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct GoalCommandTests {
  private func goal(_ status: ThreadGoal.Status = .paused, objective: String = "原目标") -> ThreadGoal
  {
    ThreadGoal(
      objective: objective, status: status, tokensUsed: 10, timeUsedSeconds: 3, tokenBudget: nil)
  }

  @Test func lifecycleActionsMatchExtensionAndUnfocusedManagementRemainsAvailable() {
    for status in [
      ThreadGoal.Status.active, .paused, .blocked, .usageLimited, .budgetLimited, .complete,
    ] {
      let state = ThreadGoal.State.available(goal(status), driver: "pi")
      #expect(GoalCommand.pause.isAvailable(in: state) == (status == .active))
      #expect(
        GoalCommand.resume.isAvailable(in: state) == (status != .active && status != .complete))
      #expect(GoalCommand.archive.isAvailable(in: state))
    }
    #expect(GoalCommand.focus.isAvailable(in: .none))
    #expect(GoalCommand.settings.isAvailable(in: .none))
    for action in GoalCommand.allCases {
      #expect(!action.isAvailable(in: .invalid))
      #expect(!action.isAvailable(in: .available(goal(), driver: "codex")))
      #expect(!action.isAvailable(in: .available(goal(), driver: nil)))
      if action != .focus && action != .settings {
        #expect(!action.isAvailable(in: .none))
      }
    }
    #expect(GoalCommand.progress.text == "/goal-status")
    #expect(GoalCommand.pause.text == "/goal-pause")
    #expect(GoalCommand.resume.text == "/goal-resume")
    #expect(GoalCommand.focus.text == "/goal-focus")
    #expect(GoalCommand.settings.text == "/goal-settings")
    #expect(GoalCommand.archive.text == "/goal-clear")
  }

  @Test func runningPauseAvailabilityDoesNotAuthorizeOtherGoalControls() throws {
    let client = T3DesktopClient()
    let model = AppModel(continueLastSession: false, restoreLastProjectOnLaunch: false)
    model.attach(to: client)
    defer {
      model.disconnect()
      client.stop()
    }
    model.currentSessionPath = "t3:running-goal"
    model.connectionState = .connected
    func apply(_ driver: String, _ status: String = "active") {
      model.apply([
        "thread": [
          "id": "running-goal", "goalDriver": driver,
          "goal": ["objective": "运行中目标", "status": status],
          "latestTurn": ["turnId": "run", "state": "running"],
        ]
      ])
    }
    apply("pi")
    #expect(!model.canPauseGoal, "离线不能发送暂停")
    client.didCompletePoll()
    #expect(model.isBusy)
    #expect(model.canPauseGoal)
    apply("codex")
    #expect(!model.canPauseGoal)
    apply("pi", "paused")
    #expect(!model.canPauseGoal)
    apply("pi", "complete")
    #expect(!model.canPauseGoal)
  }

  @Test func revisionUsesConfirmationFlowAndRejectsEmptyUnchangedOrStaleObjectives() throws {
    let original = goal()
    let revision = GoalRevision(original: original)
    let current = ThreadGoal.State.available(original, driver: "pi")
    let command = try #require(revision.command(objective: "  新目标\n保留真实测试  ", state: current))
    #expect(command.hasPrefix("/goal-tweak "))
    #expect(command.hasSuffix("新目标\n保留真实测试"))
    #expect(!command.contains("/goal-direct"))
    for text in ["", " \n ", " 原目标\n"] {
      #expect(revision.command(objective: text, state: current) == nil)
    }
    for state in [
      ThreadGoal.State.none, .invalid, .available(goal(), driver: "codex"),
      .available(goal(.complete), driver: "pi"),
      .available(goal(objective: "另一个目标"), driver: "pi"),
    ] {
      #expect(revision.command(objective: "新目标", state: state) == nil)
    }
    // 暂停/恢复或计数更新不改变正文身份；原生层不自行修改生命周期。
    #expect(
      revision.command(objective: "新目标", state: .available(goal(.active), driver: "pi")) != nil)
  }

  @Test func persistenceFailureDoesNotReportCreationOrRevisionAsSubmitted() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/goal-ui-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let directory = root.appendingPathComponent("outbox")
    let store = MessageOutboxStore(directory: directory)
    // 初始化时为空且合法，提交前让目录位置变成文件，真实触发持久化失败而非预先只读。
    try Data("blocked".utf8).write(to: directory)
    let suite = "goal-save-failure-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let client = T3DesktopClient(defaults: defaults)
    let model = AppModel(continueLastSession: false, restoreLastProjectOnLaunch: false)
    defer {
      model.disconnect()
      client.stop()
      defaults.removePersistentDomain(forName: suite)
    }
    model.attach(
      to: client, deliveries: MessageRecoveryCoordinator(store: store, transport: client))
    client.didCompletePoll()
    model.projectURL = root
    model.connectionState = .connected
    model.currentSessionPath = "t3:goal-save"
    model.selectedModelId = "test/model"
    model.composerText = "保留草稿"
    model.apply([
      "thread": [
        "id": "goal-save", "goalDriver": "pi",
        "goal": ["objective": "原目标", "status": "paused"],
      ]
    ])
    #expect(model.canSubmitPrompt)
    #expect(!model.reviseGoal(GoalRevision(original: goal()), objective: "新目标"))
    #expect(!model.startGoal(objective: "另一个目标", mode: .discuss))
    #expect(store.messages.isEmpty)
    #expect(store.failure != nil)
    #expect(model.composerText == "保留草稿")
    #expect(model.statusText.contains("保存失败"))
  }

  @Test func rejectedRevisionAndCommandsNeverConsumeComposerOrAttachments() {
    let model = AppModel(continueLastSession: false, restoreLastProjectOnLaunch: false)
    model.currentSessionPath = "t3:goal-edit"
    model.composerText = "保留未发送消息"
    model.attachments = [
      PromptAttachment(url: URL(fileURLWithPath: "/tmp/goal-edit.png"), mimeType: "image/png")
    ]
    let attachmentIDs = model.attachments.map(\.id)
    model.apply([
      "thread": [
        "id": "goal-edit", "goalDriver": "pi",
        "goal": ["objective": "原目标", "status": "paused"],
      ]
    ])
    let initial = model.goalState
    let revision = GoalRevision(original: goal())
    #expect(!model.reviseGoal(revision, objective: "新目标"))
    model.isStreaming = true
    #expect(!model.reviseGoal(revision, objective: "新目标"))
    for action in GoalCommand.allCases { model.sendGoalCommand(action) }
    #expect(model.goalState == initial)
    #expect(model.messages.isEmpty)
    #expect(model.composerText == "保留未发送消息")
    #expect(model.attachments.map(\.id) == attachmentIDs)
  }
}

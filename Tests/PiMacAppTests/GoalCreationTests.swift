import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct GoalCreationTests {
  @Test func commandsKeepGoalTextAndRejectEmptyInput() {
    #expect(GoalStartMode.discuss.command(objective: "  导出 CSV\n保留筛选  ") == "/goal 导出 CSV\n保留筛选")
    #expect(GoalStartMode.direct.command(objective: "  导出 CSV  ") == "/goal-direct 导出 CSV")
    for mode in GoalStartMode.allCases {
      #expect(mode.command(objective: " \n\t ") == nil)
    }
  }

  @Test func formActionsRouteBothModesAndCancelNeverSubmits() {
    for action in [GoalCreationAction.start(.discuss), .start(.direct), .cancel] {
      var submitted: [(String, GoalStartMode)] = []
      var dismissed = 0
      #expect(
        action.perform(
          objective: "导出 CSV", unavailableReason: nil,
          onDismiss: { dismissed += 1 },
          onStart: { text, mode in
            submitted.append((text, mode))
            return true
          }))
      #expect(dismissed == 1)
      switch action {
      case .cancel:
        #expect(submitted.isEmpty)
      case .start(let mode):
        #expect(submitted.count == 1)
        #expect(submitted.first?.0 == "导出 CSV")
        #expect(submitted.first?.1 == mode)
      }
    }
  }

  @Test func emptyBusyAndRejectedActionsKeepDialogWithoutDispatching() {
    for mode in GoalStartMode.allCases {
      for (text, reason) in [(" \n ", nil), ("导出 CSV", "会话正在执行")] {
        var sends = 0
        var dismissed = 0
        #expect(
          !GoalCreationAction.start(mode).perform(
            objective: text, unavailableReason: reason, onDismiss: { dismissed += 1 },
            onStart: { _, _ in
              sends += 1
              return true
            }))
        #expect(sends == 0)
        #expect(dismissed == 0)
      }
      var dismissed = 0
      var attempts = 0
      #expect(
        !GoalCreationAction.start(mode).perform(
          objective: "导出 CSV", unavailableReason: nil, onDismiss: { dismissed += 1 },
          onStart: { _, _ in
            attempts += 1
            return false
          }))
      #expect(attempts == 1)
      #expect(dismissed == 0)
    }
    var dismissed = 0
    #expect(
      GoalCreationAction.cancel.perform(
        objective: "", unavailableReason: "会话正在执行", onDismiss: { dismissed += 1 },
        onStart: { _, _ in
          Issue.record("取消不应提交目标")
          return false
        }))
    #expect(dismissed == 1)
  }

  @Test func disconnectedEntryRejectsStartWithoutChangingDraft() {
    let model = AppModel(continueLastSession: false, restoreLastProjectOnLaunch: false)
    model.composerText = "未发送正文"
    model.attachments = [
      PromptAttachment(url: URL(fileURLWithPath: "/tmp/unsent-goal.png"), mimeType: "image/png")
    ]
    let attachmentIDs = model.attachments.map(\.id)
    #expect(model.goalState == .none)
    #expect(model.goalCreationUnavailableReason != nil)
    #expect(!model.startGoal(objective: "导出 CSV", mode: .discuss))
    model.isStreaming = true
    #expect(model.goalCreationUnavailableReason?.contains("正在执行") == true)
    #expect(!model.startGoal(objective: "导出 CSV", mode: .direct))
    #expect(model.messages.isEmpty)
    #expect(model.composerText == "未发送正文")
    #expect(model.attachments.map(\.id) == attachmentIDs)
  }

  @Test(.timeLimit(.minutes(1)))
  func nativeStartDispatchesExactCommandsWithoutConsumingComposerOrAttachments() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/goal-entry-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fixture = try String(
      contentsOf: repository.appendingPathComponent(
        "sidecars/t3-server/tests/fixtures/pi.mjs"), encoding: .utf8
    )
    .replacingOccurrences(
      of: "commands: [",
      with:
        "commands: [{ name: 'goal', source: 'extension' }, { name: 'goal-direct', source: 'extension' }, "
    )
    try fixture.write(to: root.appendingPathComponent("pi.mjs"), atomically: true, encoding: .utf8)
    let binary = root.appendingPathComponent("pi")
    try "#!/bin/sh\nexec node '\(root.appendingPathComponent("pi.mjs").path)' \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "pimac-goal-entry-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(binary.path, forKey: "piPath")
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults)
    let client = T3DesktopClient(defaults: defaults)
    let model = AppModel(continueLastSession: false, restoreLastProjectOnLaunch: false)
    defer {
      model.disconnect()
      client.stop()
      service.stop()
      workspace.disconnectAll()
    }
    // 独立本地 Server + 脚本 Provider：只核验原生入口提交语义，不使用账户或真实模型。
    try startT3ProtocolFixture(
      service: service, workspace: workspace,
      stateDirectory: root.appendingPathComponent("state"), binary: binary, model: "test/model")
    client.start(service: service)
    try await client.waitUntilReady()
    model.attach(to: client)
    model.connect(to: root)
    for _ in 0..<200 where model.isLoadingConfiguration {
      try await Task.sleep(for: .milliseconds(25))
    }
    try #require(model.goalCreationUnavailableReason == nil)
    #expect(model.goalState == .none)
    model.composerText = "未发送正文"
    model.attachments = [
      PromptAttachment(url: root.appendingPathComponent("unsent.png"), mimeType: "image/png")
    ]
    let ids = model.attachments.map(\.id)
    for mode in GoalStartMode.allCases {
      #expect(!model.startGoal(objective: " \n ", mode: mode))
      let previous = model.lastSettledTurnID
      #expect(model.startGoal(objective: "  导出 CSV  ", mode: mode))
      #expect(!model.startGoal(objective: "不得重复启动", mode: mode))
      #expect(model.composerText == "未发送正文")
      #expect(model.attachments.map(\.id) == ids)
      for _ in 0..<400 where model.lastSettledTurnID == previous || model.isBusy {
        try await Task.sleep(for: .milliseconds(25))
      }
      try #require(model.lastSettledTurnID != previous)
      try #require(model.goalCreationUnavailableReason == nil)
    }
    let data = try String(
      contentsOf: root.appendingPathComponent("fixture-rpc.ndjson"), encoding: .utf8)
    let prompts = try data.split(separator: "\n").map {
      try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }.filter {
      // 上游会另发标题生成请求；这里只检查用户 Goal 入口，不禁用原生标题能力。
      $0["command"] as? String == "prompt"
        && ($0["message"] as? String)?.hasPrefix("/goal") == true
    }
    #expect(
      prompts.compactMap { $0["message"] as? String } == ["/goal 导出 CSV", "/goal-direct 导出 CSV"])
    #expect(prompts.allSatisfy { $0["imageCount"] as? Int == 0 })
    #expect(model.composerText == "未发送正文")
    #expect(model.attachments.map(\.id) == ids)
  }

}

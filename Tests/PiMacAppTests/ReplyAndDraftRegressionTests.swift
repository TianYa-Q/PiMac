import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ReplyAndDraftRegressionTests {
  @Test func autonomousRunDoesNotFoldEarlierFinalReply() throws {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.currentSessionPath = "t3:reply-regression"
    let items: [[String: Any]] = [
      [
        "id": "user", "runId": "first", "type": "user_message", "text": "当前进度",
        "startedAt": "2026-10-22T06:36:30Z",
      ],
      [
        "id": "answer", "runId": "first", "type": "assistant_message", "text": "## 当前进度",
        "startedAt": "2026-10-22T06:36:55Z",
      ],
      [
        "id": "tool", "runId": "background", "type": "dynamic_tool", "toolName": "read",
        "status": "completed", "startedAt": "2026-10-22T06:38:00Z",
      ],
      [
        "id": "followup", "runId": "background", "type": "assistant_message", "text": "审查结束",
        "startedAt": "2026-10-22T06:41:23Z",
      ],
    ]
    model.apply(
      T3V2Presentation.detail([
        "projection": [
          "thread": ["id": "reply-regression"],
          "runs": [
            ["id": "first", "status": "completed"],
            ["id": "background", "status": "completed"],
          ],
          "visibleTurnItems": items.map { ["item": $0] },
        ]
      ]))
    #expect(model.conversationTurns.compactMap(\.finalAssistant?.text) == ["## 当前进度", "审查结束"])
    #expect(!model.conversationTurns.flatMap(\.activity).contains { $0.id == "answer" })
    #expect(model.conversationTurns.last?.activity.first?.toolName == "read")
  }

  @Test func sameRunProgressStaysVisibleAlongsideItsFinalReply() {
    let progress = ChatEntry(
      id: "progress", kind: .assistant, title: "Pi", text: "正在检查", runID: "run")
    let thinking = ChatEntry(
      id: "thinking", kind: .thinking, title: "思考过程", text: "推理", runID: "run")
    let final = ChatEntry(
      id: "final", kind: .assistant, title: "Pi", text: "已完成", runID: "run")
    let turns = ConversationTurn.group([progress, thinking, final])
    #expect(turns.count == 1)
    #expect(turns.first?.activity == [thinking])
    #expect(turns.first?.finalAssistant == final)
    #expect(turns.first?.content == [.entry(progress), .activity([thinking]), .entry(final)])
  }

  @Test func clearedLegacyDraftDoesNotReappearBeforeConnection() throws {
    let suite = "pimac-legacy-draft-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("旧版草稿", forKey: "t3Draft.t3:first")
    let project = URL(fileURLWithPath: "/tmp/pimac-legacy-draft")
    let workspace = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    defer { workspace.disconnectAll() }
    let model = workspace.taskModel(in: project, sessionPath: "t3:first")
    #expect(model.composerText == "旧版草稿")
    model.composerText = ""
    let restored = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    defer { restored.disconnectAll() }
    #expect(restored.taskModel(in: project, sessionPath: "t3:first").composerText.isEmpty == true)
  }

  @Test func corruptDraftIsReportedAndPreservedInsteadOfTreatedAsEmpty() throws {
    let suite = "pimac-corrupt-draft-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("损坏记录", forKey: "t3ComposerDraft.session.t3:first")
    let workspace = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    defer { workspace.disconnectAll() }
    let model = workspace.taskModel(
      in: URL(fileURLWithPath: "/tmp/pimac-corrupt-draft"), sessionPath: "t3:first")
    #expect(model.statusText.contains("草稿记录损坏"))
    #expect(defaults.string(forKey: "t3ComposerDraft.session.t3:first") == "损坏记录")
  }

  @Test func draftTextAndAttachmentsSurviveWorkspaceRecreation() throws {
    let suite = "pimac-composer-draft-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let project = URL(fileURLWithPath: "/tmp/pimac-draft-recreation")
    let attachment = PromptAttachment(
      url: URL(fileURLWithPath: "/tmp/pi-clipboard-draft.png"), mimeType: "image/png")
    let text = "保留图片 \(attachment.composerReference)"
    let original = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    original.newSession(in: project)
    let draft = try #require(original.selectedModel)
    draft.composerText = text
    draft.attachments = [attachment]
    original.disconnectAll()

    let restored = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    defer { restored.disconnectAll() }
    restored.newSession(in: project)
    #expect(restored.selectedModel?.composerText == text)
    #expect(restored.selectedModel?.attachments == [attachment])
    #expect(
      restored.selectedModel?.attachments.first?.composerReference == attachment.composerReference)

    restored.selectedModel?.composerText = ""
    restored.selectedModel?.attachments = []
    let empty = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    defer { empty.disconnectAll() }
    empty.newSession(in: project)
    #expect(empty.selectedModel?.hasUnsubmittedInput == false)
  }

  @Test func migrationRebindsAnUnchangedComposerDraftBeforeAnyFurtherTyping() throws {
    let suite = "pimac-migration-draft-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let project = URL(fileURLWithPath: "/tmp/pimac-migration-draft")
    let original = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    defer { original.disconnectAll() }
    original.newSession(in: project)
    let model = try #require(original.selectedModel)
    model.currentSessionPath = "t3:source"
    model.composerText = "迁移时另外正在编辑的内容"
    model.attachments = [
      PromptAttachment(url: project.appendingPathComponent("notes.txt"), mimeType: "text/plain")
    ]
    model.currentSessionPath = "t3:target"
    let restored = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    defer { restored.disconnectAll() }
    let target = restored.taskModel(in: project, sessionPath: "t3:target")
    #expect(target.composerText == "迁移时另外正在编辑的内容")
    #expect(target.attachments == model.attachments)
  }

  @Test func sessionDraftsStaySeparateAndSaveBeforeConnectionCompletes() throws {
    let suite = "pimac-session-draft-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let project = URL(fileURLWithPath: "/tmp/pimac-session-draft")
    let original = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    let first = original.taskModel(in: project, sessionPath: "t3:first")
    let second = original.taskModel(in: project, sessionPath: "t3:second")
    first.composerText = "会话一"
    second.composerText = "会话二"
    let attachment = PromptAttachment(
      url: URL(fileURLWithPath: "/tmp/session-document.txt"), mimeType: "text/plain")
    second.attachments = [attachment]
    original.disconnectAll()

    let restored = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    defer { restored.disconnectAll() }
    #expect(restored.taskModel(in: project, sessionPath: "t3:first").composerText == "会话一")
    let restoredSecond = restored.taskModel(in: project, sessionPath: "t3:second")
    #expect(restoredSecond.composerText == "会话二")
    #expect(restoredSecond.attachments == [attachment])
    restored.newSession(in: project)
    #expect(restored.selectedModel?.hasUnsubmittedInput == false)
  }

  @Test func attachmentOnlyDraftSurvivesAndDoesNotLeakBetweenProjects() throws {
    let suite = "pimac-attachment-draft-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = URL(fileURLWithPath: "/tmp/pimac-first-project")
    let second = URL(fileURLWithPath: "/tmp/pimac-second-project")
    let attachment = PromptAttachment(
      url: URL(fileURLWithPath: "/tmp/attachment-only.txt"), mimeType: "text/plain")
    let original = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    original.newSession(in: first)
    original.selectedModel?.attachments = [attachment]
    original.disconnectAll()

    let restored = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    defer { restored.disconnectAll() }
    restored.newSession(in: second)
    #expect(restored.selectedModel?.hasUnsubmittedInput == false)
    restored.newSession(in: first)
    #expect(restored.selectedModel?.composerText == "")
    #expect(restored.selectedModel?.attachments == [attachment])
  }

  @Test func remoteNewTaskDoesNotReadOrOverwriteDesktopProjectDraft() throws {
    let suite = "pimac-remote-draft-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let project = URL(fileURLWithPath: "/tmp/pimac-remote-draft")
    let workspace = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    defer { workspace.disconnectAll() }
    workspace.newSession(in: project)
    let desktop = try #require(workspace.selectedModel)
    desktop.composerText = "桌面未发送内容"
    let attachment = PromptAttachment(
      url: URL(fileURLWithPath: "/tmp/desktop-private.txt"), mimeType: "text/plain")
    desktop.attachments = [attachment]
    let remote = workspace.taskModel(in: project, sessionPath: nil)
    #expect(remote.composerText.isEmpty)
    #expect(remote.attachments.isEmpty)
    remote.composerText = "远程内容"

    let restored = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    defer { restored.disconnectAll() }
    restored.newSession(in: project)
    #expect(restored.selectedModel?.composerText == "桌面未发送内容")
    #expect(restored.selectedModel?.attachments == [attachment])
  }

  @Test func newChatReturnsToUnsentDraftAfterOpeningAnotherChat() throws {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let project = URL(fileURLWithPath: "/tmp/pimac-draft-regression")
    workspace.newSession(in: project)
    let draft = try #require(workspace.selectedModel)
    draft.composerText = "尚未发送的文字"
    let attachment = PromptAttachment(
      url: URL(fileURLWithPath: "/tmp/pimac-draft-regression.txt"), mimeType: "text/plain")
    draft.attachments = [attachment]
    _ = workspace.taskModel(in: project, sessionPath: "t3:another-chat")
    workspace.newSession(in: project)
    #expect(workspace.selectedModel === draft)
    #expect(workspace.selectedModel?.composerText == "尚未发送的文字")
    #expect(workspace.selectedModel?.attachments == [attachment])
  }
}

import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ImmediateSubmissionTests {
  @Test func acceptedMessageIsVisibleBeforeProviderTimelineAndDeduplicatesByIdentity() throws {
    let source: [String: Any] = [
      "id": "message", "role": "user", "text": "立即显示", "runId": "run",
      "createdAt": "2026-10-24T00:00:01Z", "attachments": [],
    ]
    var projection: [String: Any] = [
      "thread": ["id": "thread"], "messages": [source],
      "runs": [["id": "run", "status": "starting", "userMessageId": "message"]],
      "visibleTurnItems": [],
    ]
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.currentSessionPath = "t3:thread"
    model.apply(T3V2Presentation.detail(["projection": projection]))
    #expect(model.messages.map(\.id) == ["message"])
    #expect(model.messages.first?.text == "立即显示")

    projection["visibleTurnItems"] = [
      [
        "item": [
          "id": "item", "messageId": "message", "type": "user_message",
          "text": "立即显示", "startedAt": "2026-10-24T00:00:01Z",
        ]
      ]
    ]
    model.apply(T3V2Presentation.detail(["projection": projection]))
    #expect(model.messages.map(\.id) == ["message"])

    // 队列未执行前不进入历史，取消后也不留下本地伪造的正文。
    projection["visibleTurnItems"] = []
    projection["runs"] = [["id": "run", "status": "queued", "userMessageId": "message"]]
    model.apply(T3V2Presentation.detail(["projection": projection]))
    #expect(model.messages.isEmpty)
    #expect(model.queuedPrompts.map(\.text) == ["立即显示"])
    projection["runs"] = [["id": "run", "status": "cancelled", "userMessageId": "message"]]
    model.apply(T3V2Presentation.detail(["projection": projection]))
    #expect(model.messages.isEmpty)
    #expect(model.queuedPrompts.isEmpty)
  }

  @Test func newSubmissionAppearsInSidebarSynchronouslyAndHandsOffToShell() throws {
    let suite = "pimac-immediate-send-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = WorkspaceModel(
      restoreUserState: false, server: T3DesktopClient(defaults: defaults))
    defer { workspace.disconnectAll() }
    workspace.server.didCompletePoll()
    let model = try #require(workspace.selectedModel)
    model.projectURL = URL(fileURLWithPath: "/tmp/pimac-immediate-send")
    model.connectionState = .connected
    model.composerText = "第一条消息"
    model.sendPrompt()
    let id = try #require(model.threadID)
    #expect(model.messages.last?.text == "第一条消息")
    #expect(workspace.filteredSessions.map(\.path) == ["t3:\(id)"])
    #expect(workspace.filteredSessions.first?.title == "第一条消息")
    #expect(workspace.filteredSessions(settled: true).isEmpty)
    // 旧列表仍为空时，本地提交必须保持可见。
    workspace.server.applyShell(["threads": []])
    #expect(workspace.filteredSessions.map(\.path) == ["t3:\(id)"])
    #expect(!model.statusText.contains("归档或移除"))
    workspace.server.applyShell([
      "projects": [["id": "p", "workspaceRoot": "/tmp/pimac-immediate-send"]],
      "threads": [["id": id, "projectId": "p", "title": "Server 标题"]],
    ])
    #expect(workspace.filteredSessions.map(\.path) == ["t3:\(id)"])
    #expect(workspace.filteredSessions.first?.title == "Server 标题")
  }

  @Test func sentSessionCanReopenAfterNewChatBeforeShellCatchesUp() throws {
    let suite = "pimac-send-new-chat-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = WorkspaceModel(
      restoreUserState: false, server: T3DesktopClient(defaults: defaults))
    defer { workspace.disconnectAll() }
    let project = URL(fileURLWithPath: "/tmp/pimac-send-new-chat")
    workspace.server.didCompletePoll()
    workspace.server.applyShell([
      "projects": [["id": "p", "workspaceRoot": project.path]], "threads": [],
    ])
    let original = try #require(workspace.selectedModel)
    original.projectURL = project
    original.connectionState = .connected
    original.isLoadingConfiguration = false
    original.composerText = "发送后立即新聊天"
    original.sendPrompt()
    let path = original.currentSessionPath
    let id = try #require(original.threadID)
    let messageIDs = original.messages.map(\.id)
    #expect(workspace.server.thread(id) == nil)

    workspace.newSessionInLastProject()
    let draft = try #require(workspace.selectedModel)
    #expect(draft !== original)
    draft.composerText = "新聊天草稿"
    let tabCount = workspace.tabs.count
    #expect(workspace.project(forSessionPath: path)?.url == project)
    workspace.openSession(path: path, in: project)

    #expect(workspace.selectedModel === original)
    #expect(original.currentSessionPath == path)
    #expect(original.messages.map(\.id) == messageIDs)
    #expect(workspace.tabs.count == tabCount)
    #expect(draft.composerText == "新聊天草稿")
    #expect(!draft.statusText.contains("尚未导入"))

    // shell 到达后仍恢复同一模型，不能另建标签或重复提交。
    workspace.server.applyShell([
      "projects": [["id": "p", "workspaceRoot": project.path]],
      "threads": [["id": id, "projectId": "p", "title": "Server 标题"]],
    ])
    workspace.newSessionInLastProject()
    workspace.openSession(path: path, in: project)
    #expect(workspace.selectedModel === original)
    #expect(workspace.tabs.count == tabCount)

    // 本地优先不能绕过项目身份边界。
    workspace.newSessionInLastProject()
    workspace.openSession(path: path, in: URL(fileURLWithPath: "/tmp/another-project"))
    #expect(workspace.selectedModel === draft)
  }

  @Test func disconnectedSendPreservesDraftAndReportsConnectionInsteadOfThreadRecycling() {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.composerText = "保留草稿"
    model.sendPrompt()
    #expect(model.composerText == "保留草稿")
    #expect(model.messages.isEmpty)
    #expect(model.statusText.contains("T3 Server"))
    #expect(model.statusText.contains("草稿已保留"))
  }
}

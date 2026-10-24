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

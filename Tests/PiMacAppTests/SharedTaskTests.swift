import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct SharedTaskTests {
  @Test func allInputsUseTheSameNormalization() throws {
    #expect(AppModel.makePrompt(" \n ", attachments: [], delivery: .steer) == nil)
    let prompt = try #require(
      AppModel.makePrompt(" \n hello \n ", attachments: [], delivery: .followUp))
    #expect(prompt.text == "hello")
    #expect(prompt.rpcText == "hello")
    #expect(prompt.delivery == .followUp)
  }

  @Test func attachmentOnlyInputUsesSharedFallback() throws {
    let attachment = PromptAttachment(
      url: URL(fileURLWithPath: "/tmp/report.pdf"), mimeType: "application/pdf")
    let prompt = try #require(
      AppModel.makePrompt(" \n", attachments: [attachment], delivery: .steer))
    #expect(prompt.text == "请查看附件。")
    #expect(prompt.attachments == [attachment])
    #expect(prompt.rpcText == AppModel.rpcText(for: prompt.text, attachments: [attachment]))
  }

  @Test func remoteRejectionPreservesDesktopDraft() {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.composerText = "desktop draft"
    let attachment = PromptAttachment(
      url: URL(fileURLWithPath: "/tmp/desktop.pdf"), mimeType: "application/pdf")
    model.attachments = [attachment]
    var accepted: Bool?
    model.sendRemotePrompt("remote task") { accepted = $0 }
    #expect(accepted == false)
    #expect(model.composerText == "desktop draft")
    #expect(model.attachments == [attachment])
    #expect(model.messages.isEmpty)
  }

  @Test func remoteAndDesktopResolveOneRuntimeWithoutChangingSelection() {
    let workspace = WorkspaceModel()
    defer {
      workspace.telegram.stop()
      for tab in workspace.tabs { tab.model.disconnect() }
    }
    let selection = workspace.selectedTabID
    let project = URL(fileURLWithPath: "/tmp/shared-task-\(UUID().uuidString)")
    let path = project.appendingPathComponent("session.jsonl").path
    let remote = workspace.taskModel(in: project, sessionPath: path)
    #expect(workspace.selectedTabID == selection)
    #expect(remote.extensionUI === workspace.extensionUI)
    #expect(workspace.taskModel(in: project, sessionPath: path) === remote)
    workspace.openSession(path: path, in: project)
    #expect(workspace.selectedModel === remote)
    #expect(workspace.tabs.filter { $0.model === remote }.count == 1)
  }

  @Test func differentSessionsKeepIndependentRuntimes() {
    let workspace = WorkspaceModel()
    defer {
      workspace.telegram.stop()
      for tab in workspace.tabs { tab.model.disconnect() }
    }
    let project = URL(fileURLWithPath: "/tmp/shared-task-\(UUID().uuidString)")
    let first = workspace.taskModel(in: project, sessionPath: "/tmp/first.jsonl")
    let second = workspace.taskModel(in: project, sessionPath: "/tmp/second.jsonl")
    #expect(first !== second)
    #expect(workspace.model(forSessionPath: "/tmp/first.jsonl") === first)
    #expect(workspace.model(forSessionPath: "/tmp/second.jsonl") === second)
  }
}

import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3WorkspaceReadModelTests {
  @Test func privateTranscriptIsBoundedAndDoesNotExportAttachments() throws {
    let input = [
      ChatEntry(id: "user", kind: .user, title: "You", text: "hello"),
      ChatEntry(id: "reasoning", kind: .thinking, title: "Thinking", text: "trace"),
      ChatEntry(
        id: "tool-call", kind: .tool, title: "read", text: "file", isRunning: true,
        toolInput: "README.md"),
    ]
    let result = try T3WorkspaceReadModel.transcript(input)
    let entries = try #require(result["entries"] as? [[String: Any]])
    #expect(entries.map { $0["kind"] as? String } == ["user", "reasoning", "tool"])
    #expect(entries.last?["input"] as? String == "README.md")
    #expect(entries.last?["running"] as? Bool == true)
    #expect(entries.allSatisfy { $0["attachments"] == nil })
    #expect(JSONSerialization.isValidJSONObject(result))
  }

  @Test func excessiveAndEscapeHeavyTranscriptsFailRatherThanTruncate() {
    let entry = ChatEntry(id: "x", kind: .assistant, title: "Pi", text: "x")
    #expect(throws: T3WorkspaceReadModel.ReadError.self) {
      _ = try T3WorkspaceReadModel.transcript(Array(repeating: entry, count: 20001))
    }
    let escaped = ChatEntry(
      id: "x", kind: .assistant, title: "Pi", text: String(repeating: "\\", count: 4_300_000))
    #expect(throws: T3WorkspaceReadModel.ReadError.self) {
      _ = try T3WorkspaceReadModel.transcript([escaped])
    }
  }

  @Test func runtimeReuseCannotReadAReplacementSession() throws {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let tab = try #require(workspace.tabs.first)
    tab.model.currentSessionPath = "/replacement.jsonl"
    tab.model.composerText = "keep composer"
    let selection = workspace.selectedTabID
    let bridge = RemoteWorkspaceBridge(workspace: workspace)
    var code: String?
    bridge.handle(
      RemoteBridgeRequest(
        id: "read", method: "session.read", target: tab.id.uuidString,
        sessionPath: "/original.jsonl", projectPath: "/project")
    ) { code = ($0["error"] as? [String: String])?["code"] }
    #expect(code == "stale_target")
    #expect(tab.model.currentSessionPath == "/replacement.jsonl")
    #expect(tab.model.composerText == "keep composer")
    #expect(workspace.selectedTabID == selection)
  }

  @Test func catalogDoesNotIncludeLoadedTranscriptOrComposer() throws {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let tab = try #require(workspace.tabs.first)
    tab.model.messages = [ChatEntry(id: "private", kind: .user, title: "You", text: "secret-body")]
    tab.model.composerText = "secret-composer"
    let data = try JSONSerialization.data(withJSONObject: T3WorkspaceReadModel.catalog(workspace))
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("secret-body"))
    #expect(!text.contains("secret-composer"))
  }
}

import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct WorkspaceRestoreTests {
  @Test func switchingProjectsPreservesTheSelectedNewSession() {
    let first = URL(fileURLWithPath: "/tmp/pi-workspace-first")
    let second = URL(fileURLWithPath: "/tmp/pi-workspace-second")

    #expect(WorkspaceModel.shouldDiscardDraftOnTabSwitch(from: first, to: second) == false)
    #expect(WorkspaceModel.shouldDiscardDraftOnTabSwitch(from: second, to: first) == false)
    #expect(WorkspaceModel.shouldDiscardDraftOnTabSwitch(from: first, to: first))
  }

  @Test func defaultSessionSearchOnlyVisitsTheActiveProject() {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    #expect(
      AppModel.sessionSearchRoot(
        for: "/Users/example/work", root: root
      ).lastPathComponent == "--Users-example-work--")
    let customRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "imported-sessions")
    #expect(AppModel.sessionSearchRoot(for: "/Users/example/work", root: customRoot) == customRoot)
  }

  @Test func launchChoosesMostRecentUserOrAssistantReplyWithinFiveMinutes() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-restore-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
    let cutoff = now.addingTimeInterval(-300)
    let project = "/tmp/workspace-restore-project"

    func record(_ value: [String: Any]) throws -> Data {
      var data = try JSONSerialization.data(withJSONObject: value)
      data.append(0x0A)
      return data
    }
    func session(
      _ name: String, projectPath: String = project,
      messages: [(String, TimeInterval, Any)]
    ) throws -> String {
      var data = try record(["type": "session", "cwd": projectPath])
      for (role, age, content) in messages {
        data.append(
          try record([
            "type": "message",
            "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(age)),
            "message": ["role": role, "content": content],
          ]))
      }
      let url = root.appendingPathComponent("\(name).jsonl")
      try data.write(to: url)
      return url.resolvingSymlinksInPath().path
    }

    _ = try session("old", messages: [("user", -301, "old")])
    #expect(
      AppModel.mostRecentConversationSession(
        for: project, since: cutoff, now: now, root: root) == nil)
    _ = try session("boundary", messages: [("user", -300, "just in time")])
    let boundary = try #require(
      AppModel.mostRecentConversationSession(
        for: project, since: cutoff, now: now, root: root))
    #expect(boundary.hasSuffix("/boundary.jsonl"))
    _ = try session("user", messages: [("user", -200, "question")])
    let user = try #require(
      AppModel.mostRecentConversationSession(
        for: project, since: cutoff, now: now, root: root))
    #expect(user.hasSuffix("/user.jsonl"))
    _ = try session(
      "reply",
      messages: [
        ("user", -1000, "question"),
        ("assistant", -30, [["type": "text", "text": "answer"]]),
      ])
    let reply = try #require(
      AppModel.mostRecentConversationSession(
        for: project, since: cutoff, now: now, root: root))
    #expect(reply.hasSuffix("/reply.jsonl"))
    _ = try session(
      "tool",
      messages: [
        ("user", -1000, "question"),
        ("assistant", -10, [["type": "toolCall", "name": "bash"]]),
      ])
    _ = try session("other-project", projectPath: "/tmp/other", messages: [("user", -2, "hi")])
    #expect(
      AppModel.mostRecentConversationSession(
        for: project, since: cutoff, now: now, root: root) == reply)
    #expect(
      AppModel.mostRecentConversationSession(
        for: project, since: cutoff, now: now, archivedPaths: [reply], root: root) == user)
    #expect(
      AppModel.mostRecentConversationSession(
        for: project, since: cutoff, now: now, archivedPaths: [reply, user, boundary], root: root)
        == nil)
  }
}

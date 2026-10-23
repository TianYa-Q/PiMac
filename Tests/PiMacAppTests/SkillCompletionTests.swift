import AppKit
import Foundation
import Testing

@testable import PiMacApp

struct SkillCompletionTests {
  private func skill(
    name: String, enabled: Bool = true, userInvocable: Bool = true
  ) throws -> ComposerSkill {
    let data = try JSONSerialization.data(withJSONObject: [
      "name": name, "path": "/skills/\(name)/SKILL.md", "enabled": enabled,
      "userInvocable": userInvocable, "displayName": "技能 \(name)",
      "description": "测试说明",
    ])
    return try JSONDecoder().decode(ComposerSkill.self, from: data)
  }

  @Test func triggersOnlyLeadingCommandsWithoutSelection() {
    #expect(
      SkillCompletion.trigger(text: "/", selection: NSRange(location: 1, length: 0))?.query == "")
    #expect(
      SkillCompletion.trigger(text: "/skill:review", selection: NSRange(location: 13, length: 0))?
        .query == "review")
    for text in ["https://example.com", "请查看 /tmp", " /review", "/review 参数", "正文\n/review"] {
      #expect(
        SkillCompletion.trigger(
          text: text, selection: NSRange(location: text.utf16.count, length: 0))
          == nil)
    }
    #expect(
      SkillCompletion.trigger(text: "/review", selection: NSRange(location: 0, length: 0)) == nil)
    #expect(
      SkillCompletion.trigger(text: "/review", selection: NSRange(location: 1, length: 2)) == nil)
    #expect(SkillCompletion.trigger(text: "/", selection: NSRange(location: 20, length: 0)) == nil)
  }

  @Test func filtersDisabledAndAgentOnlySkillsAndSearchesMetadata() throws {
    let review = try skill(name: "review")
    let skills = [
      try skill(name: "zebra"), review, review,
      try skill(name: "disabled", enabled: false),
      try skill(name: "agent-only", userInvocable: false),
    ]
    #expect(SkillCompletion.matches(skills, query: "").map(\.name) == ["review", "zebra"])
    #expect(SkillCompletion.matches(skills, query: "REv").map(\.name) == ["review"])
    #expect(SkillCompletion.matches(skills, query: "技能 review").map(\.name) == ["review"])
    #expect(SkillCompletion.matches(skills, query: "测试说明").count == 2)
    #expect(SkillCompletion.matches(skills, query: "missing").isEmpty)
  }

  @Test func insertsNativePiInvocationAndPreservesRemainingPrompt() throws {
    let text = "/rev 解释这段代码 🧪"
    let trigger = try #require(
      SkillCompletion.trigger(text: text, selection: NSRange(location: 4, length: 0)))
    let (result, selection) = SkillCompletion.insert(
      try skill(name: "review"), text: text, trigger: trigger)
    #expect(result == "/skill:review  解释这段代码 🧪")
    #expect(selection == NSRange(location: 14, length: 0))
  }

  @Test func replacesWholeTokenWhenCaretIsInsideCommand() throws {
    let trigger = try #require(
      SkillCompletion.trigger(text: "/review 参数", selection: NSRange(location: 3, length: 0)))
    let (text, _) = SkillCompletion.insert(
      try skill(name: "setup"), text: "/review 参数", trigger: trigger)
    #expect(text == "/skill:setup  参数")
  }

  @MainActor
  @Test func usesOnlyExactProviderAndWorkspaceSnapshots() async throws {
    let client = T3DesktopClient()
    let checkedAt = ISO8601DateFormatter().string(from: Date())
    client.applyProviderCatalog(
      [
        [
          "instanceId": "other",
          "workspaceSnapshots": [
            ["cwd": "/project", "checkedAt": checkedAt, "skills": []]
          ],
        ],
        [
          "instanceId": "pi", "skills": [["name": "machine-only"]],
          "workspaceSnapshots": [
            ["cwd": "/project", "checkedAt": checkedAt, "skills": []],
            [
              "cwd": "/worktree", "checkedAt": checkedAt,
              "skills": [["name": "review", "path": "/skills/review", "enabled": true]],
            ],
          ],
        ],
      ], modelCatalogs: [:])
    let empty = try await client.discoverWorkspaceSkills(
      key: .init(instanceID: "pi", cwd: "/project"), fresh: false)
    let scoped = try await client.discoverWorkspaceSkills(
      key: .init(instanceID: "pi", cwd: "/worktree"), fresh: false)
    #expect(empty.skills.isEmpty)
    #expect(scoped.skills.map(\.name) == ["review"])
    #expect(empty.validatedAt == ISO8601DateFormatter().date(from: checkedAt))
    // 未发现该 cwd 时必须请求服务端；离线应报错，不能退回机器级或其他工作区的列表。
    await #expect(throws: (any Error).self) {
      try await client.discoverWorkspaceSkills(
        key: .init(instanceID: "pi", cwd: "/unknown"), fresh: false)
    }
  }

  @Test func snapshotFreshnessAndMalformedPayloadAreDistinctFromEmptySkills() throws {
    let empty = Data(
      "{\"cwd\":\"/project\",\"checkedAt\":\"2026-10-11T00:00:00.000Z\",\"skills\":[]}".utf8)
    let snapshot = try JSONDecoder().decode(SkillWorkspaceSnapshot.self, from: empty)
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-11T00:02:00Z"))
    #expect(snapshot.skills.isEmpty)
    #expect(snapshot.isCurrent(at: now))
    #expect(!snapshot.isCurrent(at: now.addingTimeInterval(181)))
    #expect(!snapshot.isCurrent(at: now.addingTimeInterval(-121)))
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        SkillWorkspaceSnapshot.self,
        from: Data("{\"cwd\":\"/project\",\"checkedAt\":\"invalid\"}".utf8))
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ComposerSkill.self, from: Data("{\"name\":\"broken\"}".utf8))
    }
  }
}

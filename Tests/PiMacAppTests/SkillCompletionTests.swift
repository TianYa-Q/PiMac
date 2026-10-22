import AppKit
import Foundation
import SwiftUI
import Testing
import Vision

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

  @MainActor
  private final class ListFixture: ObservableObject {
    @Published var query = ""
    let skills: [ComposerSkill]

    init(skills: [ComposerSkill]) { self.skills = skills }
  }

  private struct FilteredList: View {
    @ObservedObject var fixture: ListFixture

    var body: some View {
      SkillCompletionList(
        skills: SkillCompletion.matches(fixture.skills, query: fixture.query),
        selectedIndex: 0, isLoading: false, hasLoaded: true, error: nil,
        onSelect: { _ in }, onRetry: {})
    }
  }

  @MainActor
  @Test func renderedRowsFollowFilteringInsteadOfReusingOldIndex() async throws {
    let fixture = ListFixture(skills: [try skill(name: "alpha"), try skill(name: "setup")])
    let host = NSHostingView(rootView: FilteredList(fixture: fixture).preferredColorScheme(.dark))
    host.frame = NSRect(x: 0, y: 0, width: 720, height: 260)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    defer { window.contentView = nil }

    // 纯筛选断言抓不到 SwiftUI 行身份复用问题；读取实际绘制的首行文字。
    func visibleText() throws -> String {
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let image = try #require(bitmap.cgImage)
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      try VNImageRequestHandler(cgImage: image).perform([request])
      return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ").lowercased()
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(try visibleText().contains("alpha"))
    fixture.query = "setup"
    try await Task.sleep(for: .milliseconds(200))
    let filtered = try visibleText()
    #expect(filtered.contains("setup"))
    #expect(!filtered.contains("alpha"))
    fixture.query = ""
    try await Task.sleep(for: .milliseconds(200))
    #expect(try visibleText().contains("alpha"))
  }

  @MainActor
  @Test func observedCacheRedrawsRowsWithoutTypingAndKeepsRowsDuringRefreshFailure() async throws {
    let cache = WorkspaceSkillCache()
    let key = WorkspaceSkillCache.Key(instanceID: "pi", cwd: "/project")
    let old = WorkspaceSkillCache.Success(skills: [try skill(name: "alpha")], validatedAt: Date())
    await cache.preload(key: key, reload: .force, now: Date()) { old }?.value
    let host = NSHostingView(
      rootView: CachedSkillCompletionList(
        cache: cache, workspaceKey: key, query: "", selectedIndex: 5,
        onSelect: { _ in }, onReload: {}))
    host.frame = NSRect(x: 0, y: 0, width: 720, height: 320)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    func visibleText() throws -> String {
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([request])
      return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ").lowercased()
    }
    var completion: CheckedContinuation<WorkspaceSkillCache.Success, any Error>?
    let refresh = cache.preload(key: key, reload: .force, now: Date()) {
      try await withCheckedThrowingContinuation { completion = $0 }
    }
    for _ in 0..<100 where completion == nil { await Task.yield() }
    try await Task.sleep(for: .milliseconds(100))
    #expect(try visibleText().contains("alpha"))
    try #require(completion).resume(
      throwing: NSError(
        domain: "refresh", code: 1, userInfo: [NSLocalizedDescriptionKey: "refresh-failed"]))
    await refresh?.value
    try await Task.sleep(for: .milliseconds(100))
    let failedText = try visibleText()
    #expect(failedText.contains("alpha"))
    #expect(failedText.contains("refresh-failed"))
    let new = WorkspaceSkillCache.Success(skills: [try skill(name: "setup")], validatedAt: Date())
    await cache.preload(key: key, reload: .force, now: Date()) { new }?.value
    try await Task.sleep(for: .milliseconds(100))
    let updated = try visibleText()
    #expect(updated.contains("setup"))
    #expect(!updated.contains("alpha"))
    #expect(!updated.contains("refresh-failed"))
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

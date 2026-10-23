import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PiMacApp

@MainActor
struct SkillPreloadLifecycleTests {
  @Test func nativeComposerEntryPreloadsBeforeSlashAndSlashNeverDiscovers() async throws {
    let skill = try JSONDecoder().decode(
      ComposerSkill.self,
      from: Data("{\"name\":\"review\",\"path\":\"/skills/review\",\"enabled\":true}".utf8))
    var calls: [(WorkspaceSkillCache.Key, Bool)] = []
    var completion: CheckedContinuation<WorkspaceSkillCache.Success, any Error>?
    let client = T3DesktopClient(skillDiscovery: { key, fresh in
      calls.append((key, fresh))
      return try await withCheckedThrowingContinuation { completion = $0 }
    })
    let workspace = WorkspaceModel(restoreUserState: false, server: client)
    let app = try #require(workspace.selectedModel)
    app.connect(to: URL(fileURLWithPath: "/project"))
    #expect(app.composerText.isEmpty)
    #expect(calls.isEmpty)
    client.applyShell(["projects": [], "threads": []])
    client.didCompletePoll()
    let host = NSHostingView(
      rootView: ContentView(tabID: try #require(workspace.selectedTabID))
        .environmentObject(app).environmentObject(workspace)
        .environmentObject(workspace.extensionUI))
    host.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer {
      window.contentView = nil
      workspace.disconnectAll()
    }
    for _ in 0..<100 where completion == nil { await Task.yield() }
    #expect(calls.count == 1)
    #expect(calls.first?.0.cwd == "/project")
    #expect(calls.first?.1 == false)
    #expect(app.composerText.isEmpty)
    let key = try #require(app.skillWorkspaceContext.flatMap { client.skillKey(for: $0) })
    try #require(completion).resume(returning: .init(skills: [skill], validatedAt: Date()))
    for _ in 0..<100 where client.skillCache.state(for: key).isLoading { await Task.yield() }
    #expect(client.skillCache.state(for: key).skills == [skill])
    await client.skillCache.preload(key: key, reload: .force, now: Date()) {
      .init(skills: [skill], validatedAt: .distantPast)
    }?.value
    func textEditors(in view: NSView) -> [NSTextView] {
      (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textEditors(in: $0) }
    }
    host.layoutSubtreeIfNeeded()
    let editor = try #require(textEditors(in: host).first { $0.isEditable })
    window.makeFirstResponder(editor)
    func type(_ text: String) {
      editor.insertText(
        text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }
    func pressKey(_ code: UInt16, characters: String) throws {
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
      editor.keyDown(with: event)
    }
    for text in ["/", "/rev", "/missing", "/", ""] {
      type(text)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(30))
      if let trigger = SkillCompletion.trigger(
        text: text, selection: NSRange(location: text.utf16.count, length: 0))
      {
        #expect(
          SkillCompletion.matches(client.skillCache.state(for: key).skills, query: trigger.query)
            .count == (text == "/missing" ? 0 : 1))
      }
    }
    type("/rev")
    try await Task.sleep(for: .milliseconds(30))
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    try await Task.sleep(for: .milliseconds(30))
    editor.setSelectedRange(NSRange(location: 4, length: 0))
    try await Task.sleep(for: .milliseconds(30))
    try pressKey(53, characters: "\u{1b}")
    type("/")
    try await Task.sleep(for: .milliseconds(30))
    #expect(calls.count == 1)
    client.reloadWorkspaceSkills(key: key)
    completion = nil
    for _ in 0..<100 where completion == nil { await Task.yield() }
    #expect(calls.count == 2)
    #expect(calls.last?.1 == true)
    type("/rev")
    try await Task.sleep(for: .milliseconds(30))
    try pressKey(48, characters: "\t")
    #expect(app.composerText == "/skill:review ")
    try #require(completion).resume(throwing: CocoaError(.fileReadUnknown))
    for _ in 0..<100 where client.skillCache.state(for: key).isLoading { await Task.yield() }
    #expect(client.skillCache.state(for: key).error != nil)
    type("/rev")
    try await Task.sleep(for: .milliseconds(30))
    try pressKey(48, characters: "\t")
    #expect(app.composerText == "/skill:review ")
    #expect(calls.count == 2)

    let alpha = try JSONDecoder().decode(
      ComposerSkill.self,
      from: Data("{\"name\":\"alpha\",\"path\":\"/skills/alpha\",\"enabled\":true}".utf8))
    let beta = try JSONDecoder().decode(
      ComposerSkill.self,
      from: Data("{\"name\":\"beta\",\"path\":\"/skills/beta\",\"enabled\":true}".utf8))
    for direction: UInt16 in [125, 126] {
      await client.skillCache.preload(key: key, reload: .force, now: Date()) {
        .init(skills: [alpha, beta, skill], validatedAt: Date())
      }?.value
      type("/")
      try await Task.sleep(for: .milliseconds(30))
      try pressKey(125, characters: "")
      try await Task.sleep(for: .milliseconds(30))
      try pressKey(125, characters: "")
      try await Task.sleep(for: .milliseconds(30))
      await client.skillCache.preload(key: key, reload: .force, now: Date()) {
        .init(skills: [alpha, skill], validatedAt: Date())
      }?.value
      try await Task.sleep(for: .milliseconds(30))
      try pressKey(direction, characters: "")
      try await Task.sleep(for: .milliseconds(30))
      try pressKey(48, characters: "\t")
      #expect(app.composerText == "/skill:alpha ")
    }
    #expect(calls.count == 2)
  }

  @Test func lateWorktreeResultCannotBecomeCurrentScopeAndNewOpenIgnoresOldThread() async throws {
    let alpha = try JSONDecoder().decode(
      ComposerSkill.self,
      from: Data("{\"name\":\"alpha\",\"path\":\"/skills/alpha\",\"enabled\":true}".utf8))
    var oldCompletion: CheckedContinuation<WorkspaceSkillCache.Success, Never>?
    var keys: [WorkspaceSkillCache.Key] = []
    let client = T3DesktopClient(skillDiscovery: { key, _ in
      keys.append(key)
      if key.cwd == "/worktree-a" {
        return await withCheckedContinuation { oldCompletion = $0 }
      }
      return .init(skills: [], validatedAt: Date())
    })
    let model = AppModel(
      startupProjectURL: URL(fileURLWithPath: "/project"), startupSessionPath: "t3:target",
      restoreLastProjectOnLaunch: false)
    model.attach(to: client)
    defer {
      model.disconnect()
      client.stop()
    }
    client.applyShell(["threads": [["id": "target", "worktreePath": "/worktree-a"]]])
    client.didCompletePoll()
    for _ in 0..<100 where oldCompletion == nil { await Task.yield() }
    client.applyShell(["threads": [["id": "target", "worktreePath": "/worktree-b"]]])
    let context = try #require(model.skillWorkspaceContext)
    let currentKey = try #require(client.skillKey(for: context))
    for _ in 0..<100 where client.skillCache.state(for: currentKey).isLoading { await Task.yield() }
    try #require(oldCompletion).resume(returning: .init(skills: [alpha], validatedAt: Date()))
    let oldKey = WorkspaceSkillCache.Key(instanceID: "pi", cwd: "/worktree-a")
    for _ in 0..<100 where client.skillCache.state(for: oldKey).isLoading { await Task.yield() }
    #expect(currentKey.cwd == "/worktree-b")
    #expect(client.skillCache.state(for: currentKey).skills.isEmpty)
    #expect(client.skillCache.state(for: oldKey).skills == [alpha])
    model.currentSessionPath = "t3:target"
    model.connect(to: URL(fileURLWithPath: "/new-project"))
    let newContext = try #require(model.skillWorkspaceContext)
    #expect(newContext.threadID == nil)
    #expect(client.skillKey(for: newContext)?.cwd == "/new-project")
    for _ in 0..<100 where keys.count < 3 { await Task.yield() }
    #expect(keys.map(\.cwd) == ["/worktree-a", "/worktree-b", "/new-project"])
  }

  @Test func unchangedPollRefreshesStaleInterestsAndStopRequiresNewLiveShell() async {
    var calls: [Bool] = []
    let client = T3DesktopClient(skillDiscovery: { _, fresh in
      calls.append(fresh)
      return .init(skills: [], validatedAt: Date())
    })
    let context = WorkspaceSkillContext(instanceID: "pi", projectCwd: "/project", threadID: nil)
    let first = UUID()
    let second = UUID()
    client.enterSkillWorkspace(owner: first, context: context)
    client.enterSkillWorkspace(owner: second, context: context)
    let shell: T3DesktopClient.JSON = ["threads": []]
    client.applyShell(shell)
    client.didCompletePoll()
    let key = WorkspaceSkillCache.Key(instanceID: "pi", cwd: "/project")
    for _ in 0..<100 where client.skillCache.state(for: key).isLoading { await Task.yield() }
    #expect(calls == [false])
    await client.skillCache.preload(key: key, reload: .force, now: Date()) {
      .init(skills: [], validatedAt: .distantPast)
    }?.value
    client.didCompletePoll()
    for _ in 0..<100 where client.skillCache.state(for: key).isLoading { await Task.yield() }
    #expect(calls == [false, true])
    client.stop()
    client.enterSkillWorkspace(owner: first, context: context)
    #expect(client.skillCache.state(for: key) == .idle)
    client.didCompletePoll()
    for _ in 0..<10 { await Task.yield() }
    #expect(calls.count == 2)
    client.applyShell(shell)
    client.didCompletePoll()
    for _ in 0..<100 where client.skillCache.state(for: key).isLoading { await Task.yield() }
    #expect(calls == [false, true, false])
    client.leaveSkillWorkspace(owner: first)
    client.leaveSkillWorkspace(owner: second)
    client.stop()
  }

  @Test func intendedThreadWaitsForLiveShellAndTracksAuthoritativeWorktree() async throws {
    var keys: [WorkspaceSkillCache.Key] = []
    let suite = "SkillPreloadLifecycleTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(
      try JSONSerialization.data(withJSONObject: [
        "threads": [["id": "target", "worktreePath": "/obsolete-cached-worktree"]]
      ]), forKey: "t3DesktopShellCache")
    let client = T3DesktopClient(
      defaults: defaults,
      skillDiscovery: { key, _ in
        keys.append(key)
        return .init(skills: [], validatedAt: Date())
      })
    let model = AppModel(
      startupProjectURL: URL(fileURLWithPath: "/project"), startupSessionPath: "t3:target",
      restoreLastProjectOnLaunch: false)
    model.attach(to: client)
    defer {
      model.disconnect()
      client.stop()
    }
    let context = try #require(model.skillWorkspaceContext)
    #expect(client.thread("target") != nil)
    #expect(client.skillKey(for: context) == nil)
    client.applyShell(["threads": []])
    client.didCompletePoll()
    for _ in 0..<10 { await Task.yield() }
    #expect(keys.isEmpty)
    client.applyShell([
      "threads": [["id": "target", "worktreePath": "/worktree/../worktree-a"]]
    ])
    for _ in 0..<100 where keys.isEmpty { await Task.yield() }
    #expect(keys.map(\.cwd) == ["/worktree-a"])
    client.applyShell(["threads": [["id": "target", "worktreePath": "/worktree-b"]]])
    for _ in 0..<100 where keys.count < 2 { await Task.yield() }
    #expect(keys.map(\.cwd) == ["/worktree-a", "/worktree-b"])
    model.disconnect()
    client.applyShell(["threads": [["id": "target", "worktreePath": "/worktree-c"]]])
    client.didCompletePoll()
    for _ in 0..<10 { await Task.yield() }
    #expect(keys.count == 2)
    client.stop()
    #expect(client.skillKey(for: context) == nil)
  }
}

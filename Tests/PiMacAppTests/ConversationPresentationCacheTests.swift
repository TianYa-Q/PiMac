import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ConversationPresentationCacheTests {
  private let project = URL(fileURLWithPath: "/tmp/pimac-cached-project")

  @Test func persistedBodyIncludesToolsButNeverRestoresRunningState() throws {
    let suite = "pimac-conversation-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let cache = ConversationPresentationCache(defaults: defaults)
    let child = ChatEntry(id: "child", kind: .tool, title: "read", text: "result", isRunning: true)
    let entry = ChatEntry(
      id: "tool", kind: .tool, title: "bash", text: "output", isRunning: true,
      toolInput: "pwd", childToolEntries: [child])
    cache.store(project: project, threadID: "a", title: "Cached", messages: [entry])
    cache.persist()
    let restored = ConversationPresentationCache(defaults: defaults)
    let snapshot = try #require(restored.snapshot(project: project, threadID: "a"))
    #expect(snapshot.title == "Cached")
    #expect(snapshot.messages.first?.toolInput == "pwd")
    #expect(snapshot.messages.first?.isRunning == false)
    #expect(snapshot.messages.first?.childToolEntries.first?.isRunning == false)
    #expect(snapshot.messages.first?.childToolEntries.first?.text == "result")
    #expect(restored.snapshot(project: project, threadID: "b") == nil)
    #expect(restored.snapshot(project: URL(fileURLWithPath: "/tmp/other"), threadID: "a") == nil)
  }

  @Test func emptyLiveHistoryReplacesPreviousBodyAndTitle() throws {
    let suite = "pimac-conversation-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let cache = ConversationPresentationCache(defaults: defaults)
    cache.store(
      project: project, threadID: "a", title: "Before",
      messages: [ChatEntry(id: "m", kind: .user, title: "You", text: "Before")])
    cache.store(project: project, threadID: "a", title: "After", messages: [])
    cache.persist()
    let snapshot = try #require(
      ConversationPresentationCache(defaults: defaults).snapshot(project: project, threadID: "a"))
    #expect(snapshot.messages.isEmpty)
    #expect(snapshot.title == "After")
  }

  @Test func boundedCacheEvictsWholeLeastRecentlyUsedConversations() throws {
    let suite = "pimac-conversation-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let cache = ConversationPresentationCache(defaults: defaults, maximumCount: 2)
    for id in ["a", "b"] {
      cache.store(project: project, threadID: id, title: id, messages: [])
    }
    _ = cache.snapshot(project: project, threadID: "a")
    cache.store(project: project, threadID: "c", title: "c", messages: [])
    #expect(cache.snapshot(project: project, threadID: "b") == nil)
    #expect(cache.snapshot(project: project, threadID: "a") != nil)
    cache.persist()
    let tiny = ConversationPresentationCache(defaults: defaults, maximumBytes: 8)
    #expect(tiny.snapshot(project: project, threadID: "a") == nil)
    tiny.store(project: project, threadID: "a", title: "too large", messages: [])
    tiny.persist()
    #expect(tiny.snapshot(project: project, threadID: "a") == nil)
  }

  @Test func corruptCacheDoesNotPreventLiveReplacement() throws {
    let suite = "pimac-conversation-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("invalid".utf8), forKey: "t3ConversationPresentationCache.v1")
    let cache = ConversationPresentationCache(defaults: defaults)
    #expect(cache.snapshot(project: project, threadID: "a") == nil)
    cache.store(project: project, threadID: "a", title: "Recovered", messages: [])
    cache.persist()
    #expect(
      ConversationPresentationCache(defaults: defaults).snapshot(project: project, threadID: "a")?
        .title == "Recovered")
  }

  @Test func openingRestoresImmediatelyWhileDisconnectedAndLiveSnapshotWins() throws {
    let suite = "pimac-conversation-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let client = T3DesktopClient(defaults: defaults)
    defer { client.stop() }
    let first = AppModel(startupProjectURL: project, startupSessionPath: "t3:a")
    first.attach(to: client)
    defer { first.disconnect() }
    first.apply([
      "thread": [
        "id": "a", "title": "Before",
        "messages": [["id": "m", "role": "user", "text": "Cached body"]],
      ]
    ])
    client.conversationCache.persist()
    let model = AppModel(startupProjectURL: project, startupSessionPath: "t3:a")
    model.attach(to: client)
    defer { model.disconnect() }
    #expect(model.messages.map(\.text) == ["Cached body"])
    #expect(model.isShowingCachedConversation)
    #expect(model.connectionState == .connecting)
    #expect(model.isLoadingConfiguration)
    #expect(!model.isStreaming)
    #expect(model.statusText == "正在后台核对会话…")
    #expect(!client.isConnected)
    model.composerText = "Should remain unsent"
    #expect(!model.canSubmitPrompt)
    model.apply(["thread": ["id": "other", "messages": []]])
    #expect(model.messages.map(\.text) == ["Cached body"])
    model.apply([
      "thread": [
        "id": "a", "title": "Live",
        "messages": [["id": "m", "role": "user", "text": "Live body"]],
      ]
    ])
    #expect(model.messages.map(\.text) == ["Live body"])
    #expect(!model.isShowingCachedConversation)
    #expect(model.statusText.isEmpty)
    #expect(client.conversationCache.snapshot(project: project, threadID: "a")?.title == "Live")
    model.switchSession(path: "t3:uncached", in: project)
    #expect(model.messages.isEmpty)
    #expect(!model.isShowingCachedConversation)
    model.switchSession(path: "t3:a", in: project)
    #expect(model.messages.map(\.text) == ["Live body"])
    model.switchSession(path: "t3:a", in: URL(fileURLWithPath: "/tmp/unrelated-project"))
    #expect(model.messages.isEmpty)
    #expect(!model.isShowingCachedConversation)
    model.switchSession(path: "t3:a", in: project)
    #expect(model.messages.map(\.text) == ["Live body"])
    model.newSession()
    #expect(model.messages.isEmpty)
    #expect(!model.isShowingCachedConversation)
    #expect(model.sessionName.isEmpty)
    model.switchSession(path: "t3:a", in: project)
    model.apply(["thread": ["id": "a", "messages": []]])
    #expect(model.messages.isEmpty)
    #expect(
      client.conversationCache.snapshot(project: project, threadID: "a")?.messages.isEmpty == true)
    model.newSession()
    model.messages = [ChatEntry(id: "local", kind: .system, title: "", text: "Local state")]
    model.newSession()
    #expect(model.messages.isEmpty)
  }
}

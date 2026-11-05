import AppKit
import Testing

@testable import PiMacApp

@MainActor
struct ThreadContextTests {
  private func copied() async throws -> T3ContextClipboard {
    try await T3ThreadContext.copy(
      environmentID: "environment", threadID: "source-thread", title: "优化逻辑 [进行中]\n对比")
  }

  @Test func officialClipboardRoundTripsNativeAndHTMLAndReidentifiesRepeatedPastes() async throws {
    let clipboard = try await copied()
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    try clipboard.write(to: board)
    #expect(board.types?.contains(T3ContextClipboard.nativeType) == true)
    let first = try await T3ThreadContext.paste(
      #require(T3ContextClipboard(pasteboard: board)), existing: nil, environmentID: "environment")
    let threads = try first.context.threads(in: first.text)
    #expect(threads.count == 1)
    #expect(threads.first?.threadId == "source-thread")
    #expect(threads.first?.label == "优化逻辑 进行中 对比")
    // iOS 通过 Data 写入自定义 UTI；Web/Universal Clipboard 也可能只保留 HTML。
    board.clearContents()
    board.setString(clipboard.text, forType: .string)
    board.setData(Data(clipboard.html.utf8), forType: .html)
    let second = try await T3ThreadContext.paste(
      #require(T3ContextClipboard(pasteboard: board)), existing: first.context,
      environmentID: "environment")
    let all = try second.context.threads(in: first.text + second.text)
    #expect(all.count == 2)
    #expect(Set(all.map(\.contextId)).count == 2)
    #expect(Set(all.map(\.threadId)) == ["source-thread"])
    board.clearContents()
    board.setString(clipboard.text, forType: .string)
    board.setData(Data(clipboard.fragment.utf8), forType: T3ContextClipboard.nativeType)
    #expect(T3ContextClipboard(pasteboard: board)?.fragment == clipboard.fragment)
  }

  @Test func malformedCrossEnvironmentAndOversizePayloadsAreNotImported() async throws {
    let clipboard = try await copied()
    await #expect(throws: (any Error).self) {
      try await T3ThreadContext.paste(clipboard, existing: nil, environmentID: "different")
    }
    await #expect(throws: (any Error).self) {
      try await T3ThreadContext.paste(
        T3ContextClipboard(text: clipboard.text, fragment: "{broken", html: ""),
        existing: nil, environmentID: "environment")
    }
    let unsupportedFragment: [String: Any] = [
      "version": 1, "source": ["environmentId": "environment"],
      "records": [
        [
          "version": 1, "kind": "mention", "contextId": "file", "label": "源码",
          "path": "src/file.ts",
        ]
      ],
    ]
    let unsupported = String(
      decoding: try JSONSerialization.data(withJSONObject: unsupportedFragment), as: UTF8.self)
    await #expect(throws: (any Error).self) {
      try await T3ThreadContext.paste(
        T3ContextClipboard(
          text: "[源码](t3-context://v1/mention/file)", fragment: unsupported, html: ""),
        existing: nil, environmentID: "environment")
    }
    var fragment = try #require(
      JSONSerialization.jsonObject(with: Data(clipboard.fragment.utf8)) as? [String: Any])
    let record = try #require((fragment["records"] as? [[String: Any]])?.first)
    fragment["records"] = Array(repeating: record, count: 201)
    let oversized = String(
      decoding: try JSONSerialization.data(withJSONObject: fragment), as: UTF8.self)
    await #expect(throws: (any Error).self) {
      try await T3ThreadContext.paste(
        T3ContextClipboard(text: clipboard.text, fragment: oversized, html: ""),
        existing: nil, environmentID: "environment")
    }
  }

  @Test func draftAndOutboxKeepPayloadAndDispatchPrunesDeletedReferences() async throws {
    let pasted = try await T3ThreadContext.paste(
      copied(), existing: nil, environmentID: "environment")
    let draft = ComposerDraft(text: pasted.text, attachments: [], messageContext: pasted.context)
    let restored = try PropertyListDecoder().decode(
      ComposerDraft.self, from: PropertyListEncoder().encode(draft))
    #expect(restored.messageContext == pasted.context)
    let plain = ComposerDraft(text: "旧草稿", attachments: [])
    #expect(
      try PropertyListDecoder().decode(
        ComposerDraft.self, from: PropertyListEncoder().encode(plain)
      ).messageContext == nil)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/desktop-thread-context/outbox-\(UUID().uuidString)")
    let store = MessageOutboxStore(directory: root)
    let prompt = try #require(
      AppModel.makePrompt(
        pasted.text, attachments: [], delivery: .steer, messageContext: pasted.context))
    let record = try store.save(
      prompt: prompt, messageID: "message", threadID: "target", project: root,
      selection: ["instanceId": "pi", "model": "test/model"], createsThread: true, context: "")
    let reloaded = MessageOutboxStore(directory: root)
    #expect(reloaded.message(record.id)?.messageContext == pasted.context)
    #expect(reloaded.message(record.id)?.entry.messageContext == pasted.context)
    let fields = try await T3ThreadContext.dispatchContext(
      text: pasted.text, context: pasted.context, environmentID: "environment")
    #expect(T3MessageContext.read(fields["context"]) == pasted.context)
    let removed = try await T3ThreadContext.dispatchContext(
      text: "已删除引用", context: pasted.context, environmentID: "environment")
    #expect(removed.isEmpty)
    let unavailable = try await T3ThreadContext.dispatchContext(
      text: pasted.text, context: nil, environmentID: "environment")
    #expect(unavailable.isEmpty)
    await #expect(throws: (any Error).self) {
      try await T3ThreadContext.dispatchContext(
        text: pasted.text, context: pasted.context, environmentID: "different")
    }
    var differentPrompt = prompt
    differentPrompt.messageContext = nil
    #expect(throws: (any Error).self) {
      try store.save(
        prompt: differentPrompt, messageID: record.id, threadID: "target", project: root,
        selection: [:], createsThread: true, context: "")
    }
  }

  @Test func actualWorkspacePersistenceKeepsContextWithItsOwnSession() async throws {
    let pasted = try await T3ThreadContext.paste(
      copied(), existing: nil, environmentID: "environment")
    let suite = "pimac-thread-draft-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let project = URL(fileURLWithPath: "/tmp/pimac-thread-context-draft")
    let original = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    let first = original.taskModel(in: project, sessionPath: "t3:first")
    first.composerText = pasted.text
    first.composerContext = pasted.context
    let second = original.taskModel(in: project, sessionPath: "t3:second")
    second.composerText = "独立草稿"
    original.disconnectAll()
    let restored = WorkspaceModel(restoreUserState: false, draftDefaults: defaults)
    defer { restored.disconnectAll() }
    let restoredFirst = restored.taskModel(in: project, sessionPath: "t3:first")
    #expect(restoredFirst.composerText == pasted.text)
    #expect(restoredFirst.composerContext == pasted.context)
    let restoredSecond = restored.taskModel(in: project, sessionPath: "t3:second")
    #expect(restoredSecond.composerText == "独立草稿")
    #expect(restoredSecond.composerContext == nil)
  }

  @Test func nativePasteCommitsTextAndPayloadTogetherButDiscardsLateResults() async throws {
    let clipboard = try await copied()
    let pasted = try await T3ThreadContext.paste(
      clipboard, existing: nil, environmentID: "environment")
    let editor = ComposerTextView.SubmitTextView()
    var accepted: T3MessageContext?
    var errors: [String] = []
    var pending = false
    editor.onPastePendingChange = { pending = $0 }
    editor.onPasteError = { errors.append($0) }
    editor.onPrepareContextPaste = { _ in pasted }
    editor.onAcceptContextPaste = { accepted = $0 }
    editor.string = "进度："
    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    editor.pasteContext(clipboard)
    #expect(pending)
    for task in Array(editor.imagePasteTasks.values) { await task.value }
    #expect(editor.string == "进度：" + pasted.text)
    #expect(accepted == pasted.context)
    #expect(!pending)

    accepted = nil
    editor.pasteContext(clipboard)
    let cancelledTasks = Array(editor.imagePasteTasks.values)
    editor.pasteContextID = "another-thread"
    editor.string = "新会话"
    for task in cancelledTasks { await task.value }
    #expect(accepted == nil)
    #expect(editor.string == "新会话")

    editor.pasteContext(clipboard)
    let tasks = Array(editor.imagePasteTasks.values)
    editor.insertText("继续输入", replacementRange: NSRange(location: 0, length: 0))
    for task in tasks { await task.value }
    #expect(accepted == nil)
    #expect(editor.string == "继续输入新会话")
    #expect(errors.count == 1)

    let original = editor.string
    editor.onPrepareContextPaste = { _ in throw CocoaError(.coderReadCorrupt) }
    editor.pasteContext(clipboard)
    for task in Array(editor.imagePasteTasks.values) { await task.value }
    #expect(editor.string == original)
    #expect(accepted == nil)
    #expect(errors.count == 2)
    #expect(!pending)
  }

  @Test func mathMessagesKeepThreadLinksAndCorruptStoredContextDoesNotBecomeEmpty() throws {
    let html = MarkdownMath.inlineHTML("[引用源](t3-context://v1/thread/source) $x + 1$")
    #expect(html.contains("href=\"t3-context://v1/thread/source\""))
    #expect(html.contains("data-tex="))
    let corrupt = try PropertyListSerialization.data(
      fromPropertyList: ["data": Data("not JSON".utf8)], format: .binary, options: 0)
    #expect(throws: (any Error).self) {
      try PropertyListDecoder().decode(T3MessageContext.self, from: corrupt)
    }
  }

  @Test func projectionAndEditingKeepContextWithoutDependingOnThreadRunningState() async throws {
    let pasted = try await T3ThreadContext.paste(
      copied(), existing: nil, environmentID: "environment")
    let detail = T3V2Presentation.detail([
      "projection": [
        "thread": ["id": "target", "title": "引用", "projectId": "p"],
        "messages": [
          ["id": "m", "role": "user", "text": pasted.text, "context": try pasted.context.object()]
        ],
        "runs": [],
        "visibleTurnItems": [
          [
            "item": [
              "id": "i", "messageId": "m", "type": "user_message", "text": pasted.text,
              "context": try pasted.context.object(),
            ]
          ]
        ],
      ]
    ])
    let model = AppModel(continueLastSession: false)
    model.currentSessionPath = "t3:target"
    model.apply(detail)
    let entry = try #require(model.messages.first { $0.id == "m" })
    #expect(entry.messageContext == pasted.context)
    model.editMessage(entry)
    #expect(model.composerContext == pasted.context)
    #expect(model.composerText == pasted.text)
  }
}

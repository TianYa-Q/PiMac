import Foundation
import Testing

@testable import PiMacApp

struct PerformanceRegressionTests {
  @Test func toolTreesKeepSiblingPathsIndependentAndStopDuplicateIDCycles() {
    let root = ChatEntry(id: "a", kind: .tool, title: "", text: "")
    let child = ChatEntry(id: "b", kind: .tool, title: "", text: "", parentToolEntryID: "a")
    let duplicate = ChatEntry(id: "a", kind: .tool, title: "", text: "", parentToolEntryID: "b")
    let sibling = ChatEntry(id: "c", kind: .tool, title: "", text: "", parentToolEntryID: "a")
    let roots = ChatEntry.groupingToolEntries([root, child, duplicate, sibling])
    #expect(roots.count == 1)
    #expect(roots.first?.childToolEntries.map(\.id) == ["b", "c"])
    #expect(roots.first?.childToolEntries.first?.childToolEntries.isEmpty == true)
    let selfLinked = ChatEntry(
      id: "self", kind: .tool, title: "", text: "", parentToolEntryID: "self")
    #expect(ChatEntry.groupingToolEntries([selfLinked]).map(\.id) == ["self"])
    #expect(ChatEntry.groupingToolEntries([child, duplicate]).isEmpty)
  }

  @Test func timelineBinarySearchMatchesOriginalScanForMissingUnsortedAndEqualDates() {
    let origin = Date(timeIntervalSince1970: 1000)
    for rotation in 0..<16 {
      let messages = (0..<32).map { index in
        ChatEntry(
          id: "m\(index)", kind: .assistant, title: "", text: "",
          timestamp: index % 5 == 0
            ? nil : origin.addingTimeInterval(Double((index + rotation) % 16)))
      }
      let children = (-1..<18).map { index in
        ConversationSubagent(
          id: "c\(index)", title: "", model: "",
          createdAt: index == -1 ? nil : origin.addingTimeInterval(Double(index)),
          status: .completed, startedAt: nil, completedAt: nil)
      }
      var groups: [Int: [ConversationSubagent]] = [:]
      for child in children {
        let boundary =
          child.createdAt.flatMap { date in
            messages.firstIndex { $0.timestamp.map { $0 > date } ?? false }
          } ?? messages.count
        groups[boundary, default: []].append(child)
      }
      var expected: [String] = []
      var start = 0
      for boundary in groups.keys.sorted() {
        expected += ConversationTurn.group(Array(messages[start..<boundary])).map {
          "turn-\($0.id)"
        }
        expected.append("subagents-\(groups[boundary]!.first!.id)")
        start = boundary
      }
      expected += ConversationTurn.group(Array(messages[start...])).map { "turn-\($0.id)" }
      #expect(
        ConversationTimelineRow.build(messages: messages, children: children).map(\.id) == expected)
      #expect(
        ConversationTimelineRow.build(messages: messages, children: []).map(\.id)
          == ConversationTurn.group(messages).map { "turn-\($0.id)" })
    }
  }

  @Test func imageLinkFastPathStillRespectsFenceStateAndInlineExamples() {
    let text = """
      ordinary text
      ```
      ![secret](secret.png)
      ```
      `![inline](inline.png)` ![actual](images/a%20b.png)
      ![same](images/a%20b.png)
      ~~~
      [example](example.png)
      ~~~
      [last](last.webp)
      """
    #expect(T3ReplyImageLinks.paths(in: text) == ["images/a b.png", "last.webp"])
    #expect(T3ReplyImageLinks.paths(in: "plain `code`\nno links").isEmpty)
  }

  @Test func indexedImageAttachmentsPreserveFirstImageAndDoNotUseNonImages() throws {
    let nonImage = PromptAttachment(
      url: URL(fileURLWithPath: "/tmp/text"), mimeType: "text/plain", replyImagePath: "a.png")
    let first = PromptAttachment(
      url: URL(fileURLWithPath: "/tmp/first.png"), mimeType: "image/png", replyImagePath: "a.png")
    let duplicate = PromptAttachment(
      url: URL(fileURLWithPath: "/tmp/second.png"), mimeType: "image/png", replyImagePath: "a.png")
    let parts = MarkdownReplyImages.parts(
      in: "![caption](a.png)", attachments: [nonImage, first, duplicate])
    #expect(parts.count == 1)
    guard case .image(let attachment, let caption) = try #require(parts.first) else {
      Issue.record("Expected first image")
      return
    }
    #expect(attachment == first)
    #expect(caption == "caption")
    #expect(MarkdownReplyImages.parts(in: "![missing](b.png)", attachments: [first]).count == 1)
  }

  @Test func telegramPlainRunsKeepEscapingGraphemesAndNestedMarkup() {
    #expect(
      TelegramMarkdown.html("中文 👩🏽‍💻 e\u{301} <x> & \"q\" **粗体** plain \\*literal\\* `a<b`")
        == "中文 👩🏽‍💻 e\u{301} &lt;x&gt; &amp; &quot;q&quot; <b>粗体</b> plain *literal* <code>a&lt;b</code>"
    )
    #expect(
      TelegramMarkdown.html("[**label**](https://example.com/?a=1&b=2)")
        == "<a href=\"https://example.com/?a=1&amp;b=2\"><b>label</b></a>")
  }

  @Test func reusedLegacyFormattersAreSafeForConcurrentImportAndTimestampFallbacks() async {
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<16 {
        group.addTask {
          let source: [[String: Any]] = [
            [
              "role": "user", "content": "fractional", "timestamp": "2026-01-01T08:00:00.123+08:00",
            ],
            ["role": "user", "content": "seconds", "timestamp": "2026-01-01T00:00:00Z"],
            ["role": "user", "content": "milliseconds", "timestamp": 1_767_225_600_123],
            ["role": "user", "content": "invalid", "timestamp": "broken"],
          ]
          let entries = AppModel.chatEntries(from: source)
          #expect(entries.count == 4)
          #expect(entries[0].timestamp == entries[2].timestamp)
          #expect(entries[1].timestamp == Date(timeIntervalSince1970: 1_767_225_600))
          #expect(entries[3].timestamp == nil)
        }
      }
    }
  }

  @MainActor
  @Test func compactionSinglePassKeepsFirstTieAndRejectsInvalidTimestamps() {
    let base: [String: Any] = [
      "type": "compaction", "status": "completed", "providerTurnId": "pt",
      "completedAt": "2026-01-01T00:00:00Z",
    ]
    let items = [11, 22, 33].map { base.merging(["afterTokenCount": $0]) { _, new in new } }
    let native: [String: Any] = [
      "projection": ["providerTurns": [["id": "pt"]], "turnItems": items]
    ]
    #expect(T3V2Presentation.stats(native)?.totalTokens == 11)
    let bad: [String: Any] = [
      "projection": [
        "providerTurns": [["id": "pt"]],
        "turnItems": [
          base.merging(["afterTokenCount": 1, "completedAt": "bad"]) { _, new in new }
        ],
      ]
    ]
    #expect(T3V2Presentation.stats(bad) == nil)
  }

  @MainActor
  @Test func queueJoinKeepsFirstDuplicateAndOriginalMissingIDSemantics() throws {
    let native: [String: Any] = [
      "projection": [
        "thread": ["id": "thread"],
        "runs": [
          ["id": "r1", "status": "queued", "userMessageId": "same", "ordinal": 1],
          ["id": "r2", "status": "queued", "ordinal": 2],
          ["id": "r3", "status": "queued", "userMessageId": "absent", "ordinal": 3],
        ],
        "messages": [
          ["id": "same", "text": "first"], ["id": "same", "text": "second"], ["text": "no id"],
        ],
      ]
    ]
    let thread = try #require(T3V2Presentation.detail(native)["thread"] as? [String: Any])
    let queue = try #require(thread["queuedMessages"] as? [[String: Any]])
    #expect(queue.compactMap { $0["text"] as? String } == ["first", "no id"])
    #expect(queue.compactMap { $0["runId"] as? String } == ["r1", "r2"])
  }

  @Test func markdownFastClassifiersRetainNumericListsDividersAndSpacedTableDelimiters() {
    #expect(MarkdownParser.parse("+2. item") == [.list(ordered: true, start: 2, items: ["item"])])
    #expect(MarkdownParser.parse("-2) item") == [.list(ordered: true, start: -2, items: ["item"])])
    #expect(MarkdownParser.parse(" * * * ") == [.divider])
    #expect(
      MarkdownParser.parse("A | B\n - - - | : - - - :\nx | y") == [
        .table(headers: ["A", "B"], rows: [["x", "y"]], alignments: [.leading, .center])
      ])
    #expect(
      MarkdownParser.parse("Ordinary prose without punctuation") == [
        .paragraph("Ordinary prose without punctuation")
      ])
  }

  @Test func jsonlVectorSearchPreservesEveryFragmentBoundaryAndOversizeRecovery() {
    let bytes = Data("\n123456789\n\r\n中\u{2028}文\r\nok\nlast".utf8)
    for split in 0...bytes.count {
      let decoder = JSONLineDecoder(maxRecordBytes: 8)
      let records = decoder.append(bytes[..<split]) + decoder.append(bytes[split...])
      // ASCII 长记录及 Unicode 记录均超出 8 字节；恢复后的短记录必须保留。
      #expect(records == [Data("ok".utf8)])
      #expect(decoder.droppedRecordCount == 2)
      #expect(decoder.finish() == Data("last".utf8))
    }
  }
}

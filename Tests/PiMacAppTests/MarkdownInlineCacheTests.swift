import Foundation
import Testing

@testable import PiMacApp

struct MarkdownInlineCacheTests {
  @Test
  func cachedParsingMatchesFoundation() throws {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace)
    for source in ["**粗体** and `code`", "[链接](https://example.com)", "第一行\n第二行", "", "*未完成"] {
      let expected = try AttributedString(markdown: source, options: options)
      #expect(MarkdownInlineCache.attributedString(for: source) == expected)
      #expect(MarkdownInlineCache.attributedString(for: source) == expected)
    }
  }

  @Test
  func streamingPrefixesDoNotReuseStaleContent() {
    let prefixes = ["hello", "hello **world", "hello **world**", "hello"]
    for source in prefixes {
      let value = MarkdownInlineCache.attributedString(for: source)
      let expected = source == "hello **world**" ? "hello world" : source
      #expect(String(value.characters) == expected)
    }
  }

  @Test
  func concurrentReadsProduceTheSameResult() async {
    let source = "**shared** `value`"
    let expected = MarkdownInlineCache.attributedString(for: source)
    await withTaskGroup(of: AttributedString.self) { group in
      for _ in 0..<32 {
        group.addTask { MarkdownInlineCache.attributedString(for: source) }
      }
      for await result in group { #expect(result == expected) }
    }
  }
}

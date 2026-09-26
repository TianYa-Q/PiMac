import XCTest
@testable import PiMacApp

final class TelegramMarkdownTests: XCTestCase {
  func testBoldItalicCodeAndEscaping() {
    XCTAssertEqual(
      TelegramMarkdown.html("**加粗**、*斜体*、`<tag>&` <hello> & __strong__"),
      "<b>加粗</b>、<i>斜体</i>、<code>&lt;tag&gt;&amp;</code> &lt;hello&gt; &amp; <b>strong</b>"
    )
    XCTAssertEqual(TelegramMarkdown.html("\\*not italic\\*"), "*not italic*")
  }

  func testLinksAndFencedCode() {
    XCTAssertEqual(
      TelegramMarkdown.html("[项目](https://example.com/?a=1&b=2)\n```swift\n**literal** <x>\n```"),
      "<a href=\"https://example.com/?a=1&amp;b=2\">项目</a>\n<pre>\n**literal** &lt;x&gt;\n</pre>"
    )
    XCTAssertEqual(TelegramMarkdown.html("[bad](javascript:alert)"), "[bad](javascript:alert)")
  }

  func testUnbalancedMarkersStaySafe() {
    XCTAssertEqual(TelegramMarkdown.html("**unfinished < &"), "**unfinished &lt; &amp;")
    XCTAssertEqual(TelegramMarkdown.html("# 标题"), "<b>标题</b>")
  }
}

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

  func testTablesBecomeLabelledRows() {
    let source = """
      对照：

      | 情况 | 实际行为 |
      |---|---|
      | 原有行为 | 输出警告，程序继续运行 |
      | 加入诊断代码 | **异常**，程序仍运行 |

      结束。
      """
    XCTAssertEqual(
      TelegramMarkdown.html(source),
      "对照：\n\n<b>情况</b>：原有行为\n<b>实际行为</b>：输出警告，程序继续运行\n\n<b>情况</b>：加入诊断代码\n<b>实际行为</b>：<b>异常</b>，程序仍运行\n\n结束。"
    )
  }

  func testTableEscapingAndMissingDelimiter() {
    XCTAssertEqual(
      TelegramMarkdown.html("Name | Value\nA | `x` & <y>"),
      "<b>Name</b>：A\n<b>Value</b>：<code>x</code> &amp; &lt;y&gt;"
    )
    XCTAssertEqual(
      TelegramMarkdown.html("| A | B |\n| --- | --- |\n| a\\|b | c |"),
      "<b>A</b>：a|b\n<b>B</b>：c"
    )
  }

  func testTablesInCodeStayLiteral() {
    let table = "| A | B |\n| --- | --- |\n| x | y |"
    XCTAssertEqual(TelegramMarkdown.html("```\n\(table)\n```"), "<pre>\n\(table)\n</pre>")
    XCTAssertEqual(TelegramMarkdown.html("a | b"), "a | b")
  }

  func testUnbalancedMarkersStaySafe() {
    XCTAssertEqual(TelegramMarkdown.html("**unfinished < &"), "**unfinished &lt; &amp;")
    XCTAssertEqual(TelegramMarkdown.html("# 标题"), "<b>标题</b>")
  }
}

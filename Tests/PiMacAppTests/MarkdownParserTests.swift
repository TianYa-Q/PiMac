import Testing

@testable import PiMacApp

struct MarkdownParserTests {
  @Test
  func parsesTheTableFormatEmittedByAssistants() throws {
    let markdown = """
      | 项目 | Shottr | AutoCAD 2027 |
      |:---|:---:|---:|
      | 主程序签名 | 第三方证书 | Ad-hoc 临时签名 |
      | Team ID | 无 | 无 |
      """

    let blocks = MarkdownParser.parse(markdown)
    #expect(blocks.count == 1)
    let block = try #require(blocks.first)
    guard case .table(let headers, let rows, let alignments) = block else {
      Issue.record("Expected a table block, got \(block)")
      return
    }

    #expect(headers == ["项目", "Shottr", "AutoCAD 2027"])
    #expect(rows.count == 2)
    #expect(rows[0] == ["主程序签名", "第三方证书", "Ad-hoc 临时签名"])
    #expect(alignments == [.leading, .center, .trailing])
  }

  @Test
  func parsesHeadingsListsQuotesCodeAndDividers() {
    let markdown = """
      ### 关键问题

      - 第一项
      - [x] 已完成

      > 引用内容

      ```swift
      let answer = 42
      ```

      ---
      """

    #expect(
      MarkdownParser.parse(markdown) == [
        .heading(level: 3, text: "关键问题"),
        .list(ordered: false, start: 1, items: ["第一项", "[x] 已完成"]),
        .quote("引用内容"),
        .code(language: "swift", text: "let answer = 42"),
        .divider,
      ])
  }

  @Test
  func infersPipeTableWhenDelimiterRowIsMissing() throws {
    let blocks = MarkdownParser.parse(
      """
      放宽原片 | 推荐原片 | 总原片 | 可复用余料 | 结果
      1 | 6 | 7 | — | 张数增加，淘汰
      2 | 4 | 6 | `2.513404m²` | 同张数基准
      """)

    #expect(blocks.count == 1)
    let block = try #require(blocks.first)
    guard case .table(let headers, let rows, let alignments) = block else {
      Issue.record("Expected an inferred table block, got \(block)")
      return
    }
    #expect(headers == ["放宽原片", "推荐原片", "总原片", "可复用余料", "结果"])
    #expect(rows.count == 2)
    #expect(rows[1][3] == "`2.513404m²`")
    #expect(alignments == Array(repeating: .leading, count: 5))
  }

  @Test
  func padsUnevenTableRowsWithoutDroppingContent() throws {
    let blocks = MarkdownParser.parse(
      """
      A | B
      --- | ---
      one | two | three
      only-one
      """)

    #expect(blocks.count == 2)
    let first = try #require(blocks.first)
    guard case .table(let headers, let rows, let alignments) = first else {
      Issue.record("Expected the first block to be a table")
      return
    }
    #expect(headers == ["A", "B", ""])
    #expect(rows == [["one", "two", "three"]])
    #expect(alignments == [.leading, .leading, .leading])
    #expect(blocks.last == .paragraph("only-one"))
  }
}

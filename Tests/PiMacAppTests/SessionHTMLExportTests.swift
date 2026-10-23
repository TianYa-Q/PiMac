import Testing

@testable import PiMacApp

@MainActor
struct SessionHTMLExportTests {
  @Test func exportFilenameIsSafeAndPreservesReadableTitles() {
    #expect(SessionHTMLExportButton.filename(title: "会话 HTML 导出") == "会话 HTML 导出.html")
    #expect(SessionHTMLExportButton.filename(title: "../路径:标题\\名称\n") == "..-路径-标题-名称.html")
    #expect(SessionHTMLExportButton.filename(title: " \n ") == "Pi 会话.html")
    #expect(SessionHTMLExportButton.filename(title: "   ") == "Pi 会话.html")
    #expect(
      SessionHTMLExportButton.filename(title: String(repeating: "长", count: 200)).count == 105)
  }
}

import Foundation
import Testing

@testable import PiMacApp

struct T3ReplyDocumentLinksTests {
  @Test func resolvesLocalDocumentsOnly() throws {
    for (target, expected) in [
      ("wxf-pending-comparison.html", "wxf-pending-comparison.html"),
      ("reports/before%20after.HTML#section", "reports/before after.HTML"),
      ("file:///tmp/report.htm", "/tmp/report.htm"),
      ("report.pdf", "report.pdf"),
    ] {
      #expect(T3ReplyDocumentLinks.path(for: try #require(URL(string: target))) == expected)
    }
    for target in ["https://example.com/report.html", "file://host/report.html", "javascript:report.html", "report.html?x=1", "a.png", "a.html%00"] {
      #expect(T3ReplyDocumentLinks.path(for: try #require(URL(string: target))) == nil)
    }
  }
}

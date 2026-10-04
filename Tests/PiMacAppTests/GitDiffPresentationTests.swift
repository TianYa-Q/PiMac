import Testing

@testable import PiMacApp

struct GitDiffPresentationTests {
  @Test func parsesHeadersHunksAndHeaderLikeContent() {
    let presentation = GitDiffPresentation(
      "diff --git a/x b/x\nindex abc..def\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n--- content\n+++ content\n unchanged\n"
    )
    #expect(
      presentation.lines.map(\.kind) == [
        .header, .header, .header, .header, .hunk, .deletion, .addition, .context,
      ])
    #expect(presentation.additions == 1 && presentation.deletions == 1)
    #expect(presentation.lines.map(\.id) == Array(1...8))
    #expect(!presentation.truncated)
  }

  @Test func searchAndScopePreserveOriginalLineNumbers() {
    let presentation = GitDiffPresentation(" context\n+你好 world\n-old WORLD\n+other")
    #expect(presentation.filtered(query: " world ", scope: .all).map(\.id) == [2, 3])
    #expect(presentation.filtered(query: "", scope: .changes).map(\.id) == [2, 3, 4])
    #expect(presentation.filtered(query: "missing", scope: .all).isEmpty)
    #expect(presentation.filtered(query: "你好", scope: .changes).map(\.id) == [2])
  }

  @Test func boundsLinesAndHandlesEmptyAndCRLFText() {
    #expect(GitDiffPresentation("").lines.isEmpty)
    let crlf = GitDiffPresentation("+你好\r\n-old\r\n")
    #expect(crlf.lines.map(\.text) == ["+你好", "-old"])
    let bounded = GitDiffPresentation("+a\n\n-b\nignored", maxLines: 3)
    #expect(bounded.lines.map(\.text) == ["+a", "", "-b"])
    #expect(bounded.truncated)
    #expect(!GitDiffPresentation("a\nb\n", maxLines: 2).truncated)
    #expect(GitDiffPresentation(String(repeating: "\n", count: 100_000)).lines.count == 10_000)
  }

  @Test func newFileResetsHunkClassification() {
    let presentation = GitDiffPresentation(
      "@@ -1 +1 @@\n+x\ndiff --git a/y b/y\n--- a/y\n+++ b/y\n@@ -1 +1 @@\n-y")
    #expect(
      presentation.lines.map(\.kind) == [
        .hunk, .addition, .header, .header, .header, .hunk, .deletion,
      ])
  }
}

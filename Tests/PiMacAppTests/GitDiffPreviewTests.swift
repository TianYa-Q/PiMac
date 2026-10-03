import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct GitDiffPreviewTests {
  private func response(_ text: String, truncated: Bool = false) -> [String: Any] {
    ["sources": [["kind": "working-tree", "diff": text, "truncated": truncated]]]
  }

  @Test func validatesConsumedFieldsInsteadOfReportingFalseEmptyDiff() throws {
    for invalid: [String: Any] in [
      [:], ["sources": "bad"], ["sources": [["kind": "working-tree"]]],
      ["sources": [["kind": "working-tree", "diff": "x", "truncated": 1]]],
    ] {
      #expect(throws: GitDiffPreview.InvalidResponse.self) {
        try GitDiffPreview.validated(invalid)
      }
    }
    #expect(try GitDiffPreview.validated(["sources": []]).text.isEmpty)
    #expect(try GitDiffPreview.validated(response("", truncated: true)).truncated)
  }

  @Test func boundsCombinedUTF8WithoutReplacementCharacters() throws {
    let preview = try GitDiffPreview.validated(response("你好世界"), maxBytes: 7)
    #expect(preview.text == "你好" && preview.truncated)
    #expect(try GitDiffPreview.validated(response("你好"), maxBytes: 6).truncated == false)
    let combined = try GitDiffPreview.validated(
      [
        "sources": [
          ["kind": "working-tree", "diff": "ab", "truncated": false],
          ["kind": "branch-range", "diff": "ignored", "truncated": false],
          ["kind": "working-tree", "diff": "cd", "truncated": false],
        ]
      ], maxBytes: 4)
    #expect(combined.text == "ab\nc" && combined.truncated)
  }

  @Test func lateSuccessAndFailureCannotReplaceNewerPreview() async {
    for fails in [false, true] {
      let store = GitDiffPreviewStore()
      await store.load {
        await store.load { response("new") }
        if fails { throw GitDiffPreview.InvalidResponse.malformed }
        return response("old")
      }
      #expect(store.preview?.text == "new")
      #expect(!store.failed && !store.loading)
    }
  }

  @Test func malformedAndCancelledRequestsHaveDistinctStates() async {
    let store = GitDiffPreviewStore()
    await store.load { [:] }
    #expect(store.failed && !store.loading && store.preview == nil)
    await store.load { throw CancellationError() }
    #expect(!store.failed && !store.loading && store.preview == nil)
    await store.load { response("recovered") }
    #expect(store.preview?.text == "recovered" && !store.failed)
  }
}

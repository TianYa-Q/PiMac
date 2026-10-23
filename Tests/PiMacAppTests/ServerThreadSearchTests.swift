import Foundation
import Testing

@testable import PiMacApp

struct ServerThreadSearchTests {
  @Test func queriesAreLiteralAndOnlyTrimmedAtTheBoundary() {
    for text in ["sync_msg", "exact phrase", "\"quoted\"", "title:库存", "foo -bar", "text:正文"] {
      let query = ServerThreadSearchQuery(" \n\(text)\t ")
      #expect(query.text == text)
      #expect(query.canSearch)
      #expect(query.validationMessage == nil)
    }
  }

  @Test func queryLengthMatchesNativeContractAndEmptyIsNotAnError() {
    let empty = ServerThreadSearchQuery(" \n ")
    #expect(!empty.canSearch)
    #expect(empty.validationMessage == nil)
    for text in ["a", String(repeating: "x", count: 201)] {
      let query = ServerThreadSearchQuery(text)
      #expect(!query.canSearch)
      #expect(query.validationMessage != nil)
    }
    for text in ["ab", "库存", String(repeating: "x", count: 200)] {
      #expect(ServerThreadSearchQuery(text).canSearch)
    }
  }

  @Test func resultsKeepServerOrderAndSnippetsWithoutLocalTitleHits() throws {
    let sessions = [
      SessionItem(path: "t3:unmatched", title: "sync_msg 标题", modifiedAt: .now),
      SessionItem(path: "t3:second", title: "第二项", modifiedAt: .now),
      SessionItem(path: "t3:first", title: "第一项", modifiedAt: .now),
    ]
    let response = try JSONDecoder().decode(
      ServerThreadSearchResponse.self,
      from: Data(
        """
        {"matches":[
          {"threadId":"first","projectId":"p","source":"user","snippet":"服务端截断的摘要","messageCreatedAt":null},
          {"threadId":"outside","projectId":"other","source":"user","snippet":"sync_msg","messageCreatedAt":null},
          {"threadId":"second","projectId":"p","source":"assistant","snippet":"sync_msg 正文","messageCreatedAt":null}
        ]}
        """.utf8))
    let results = response.results(in: sessions)
    #expect(results.map(\.id) == ["t3:first", "t3:second"])
    #expect(results.first?.snippet == "服务端截断的摘要")
    #expect(results.last?.snippet == "sync_msg 正文")
    let empty = try JSONDecoder().decode(
      ServerThreadSearchResponse.self, from: Data(#"{"matches":[]}"#.utf8))
    #expect(empty.results(in: sessions).isEmpty)
  }

  @Test func validEmptyResultsAndBrokenResponsesAreDistinct() throws {
    let empty = try JSONDecoder().decode(
      ServerThreadSearchResponse.self, from: Data(#"{"matches":[]}"#.utf8))
    #expect(empty.matches.isEmpty)
    for json in [#"{}"#, #"{"matches":[{"threadId":"one"}]}"#, #"{"matches":null}"#] {
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ServerThreadSearchResponse.self, from: Data(json.utf8))
      }
    }
  }
}

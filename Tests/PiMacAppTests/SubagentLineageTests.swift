import Foundation
import Testing
@testable import PiMacApp

@MainActor
struct SubagentLineageTests {
  @Test func usesServerLineageAndPreservesItInShell() throws {
    let child: [String: Any] = [
      "id": "child", "lineage": ["relationshipToParent": "subagent", "parentThreadId": "parent"]
    ]
    let shell = T3V2Presentation.shell(["threads": [child]])
    let threads = try #require(shell["threads"] as? [[String: Any]])
    #expect(T3V2Presentation.subagentParentID(threads[0]) == "parent")
  }

  @Test func excludesForksMissingAndInvalidParents() {
    for lineage: [String: Any] in [
      [:], ["relationshipToParent": "fork", "parentThreadId": "parent"],
      ["relationshipToParent": "subagent", "parentThreadId": NSNull()],
      ["relationshipToParent": "subagent", "parentThreadId": "  "],
      ["relationshipToParent": "subagent", "parentThreadId": "child"],
      ["relationshipToParent": "subagent", "parentThreadId": 42],
    ] {
      #expect(T3V2Presentation.subagentParentID(["id": "child", "lineage": lineage]) == nil)
    }
    #expect(T3V2Presentation.subagentParentID(["id": "normal"]) == nil)
  }

  @Test func parentNeedNotBeInVisibleList() {
    #expect(T3V2Presentation.subagentParentID([
      "id": "child", "lineage": ["relationshipToParent": "subagent", "parentThreadId": "archived-parent"]
    ]) == "archived-parent")
  }
}

import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct SubagentLineageTests {
  @Test func usesServerLineageAndPreservesItInShell() throws {
    let child: [String: Any] = [
      "id": "child", "lineage": ["relationshipToParent": "subagent", "parentThreadId": "parent"],
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

  @Test func propagatesRunningThroughNestedSubagents() {
    let threads: [[String: Any]] = [
      ["id": "parent", "status": "completed"],
      [
        "id": "child", "status": "completed",
        "lineage": ["relationshipToParent": "subagent", "parentThreadId": "parent"],
      ],
      [
        "id": "grandchild", "status": "running",
        "lineage": ["relationshipToParent": "subagent", "parentThreadId": "child"],
      ],
      ["id": "unrelated", "status": "idle"],
    ]
    #expect(
      T3V2Presentation.runningThreadIDs(threads: threads, locallyRunningIDs: [])
        == ["parent", "child", "grandchild"])
    var finished = threads
    finished[2]["status"] = "completed"
    #expect(T3V2Presentation.runningThreadIDs(threads: finished, locallyRunningIDs: []).isEmpty)
    #expect(
      T3V2Presentation.runningThreadIDs(
        threads: finished, locallyRunningIDs: ["grandchild"]) == ["parent", "child", "grandchild"])
  }

  @Test func activeChildrenIncludeWaitingButNotQueuedOrForked() {
    for status in T3V2Presentation.active + [
      "queued", "completed", "failed", "cancelled", "interrupted",
    ] {
      let threads: [[String: Any]] = [
        [
          "id": "child", "status": status,
          "lineage": ["relationshipToParent": "subagent", "parentThreadId": "parent"],
        ],
        [
          "id": "fork", "status": "running",
          "lineage": ["relationshipToParent": "fork", "parentThreadId": "fork-parent"],
        ],
      ]
      let running = T3V2Presentation.runningThreadIDs(threads: threads, locallyRunningIDs: [])
      #expect(running.contains("parent") == T3V2Presentation.active.contains(status))
      #expect(running.contains("fork"))
      #expect(!running.contains("fork-parent"))
    }
  }

  @Test func cyclicLineageTerminatesAndKeepsAllRunningAncestors() {
    let threads: [[String: Any]] = [
      [
        "id": "a", "status": "running",
        "lineage": ["relationshipToParent": "subagent", "parentThreadId": "b"],
      ],
      [
        "id": "b", "status": "idle",
        "lineage": ["relationshipToParent": "subagent", "parentThreadId": "a"],
      ],
    ]
    #expect(
      T3V2Presentation.runningThreadIDs(threads: threads, locallyRunningIDs: []) == ["a", "b"])
  }

  @Test func parentNeedNotBeInVisibleList() {
    #expect(
      T3V2Presentation.subagentParentID([
        "id": "child",
        "lineage": ["relationshipToParent": "subagent", "parentThreadId": "archived-parent"],
      ]) == "archived-parent")
  }
}

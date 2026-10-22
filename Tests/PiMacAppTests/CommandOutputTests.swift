import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct CommandOutputTests {
  typealias JSON = [String: Any]

  @Test func commandOutputSurvivesHydrationAndRevisions() async throws {
    let client = T3DesktopClient()
    let model = AppModel(continueLastSession: false)
    model.currentSessionPath = "t3:thread"
    defer {
      model.disconnect()
      client.stop()
    }
    let base = URL(string: "http://localhost:12345")!
    for (revision, status, output) in [
      ("1", "running", ""),
      ("2", "running", "first line\n"),
      ("3", "running", "first line\nsecond line\n"),
      ("4", "completed", "done\n"),
      ("5", "failed", "permission denied\n"),
    ] {
      let item: JSON = [
        "id": "command", "threadId": "owner", "runId": "run",
        "type": "command_execution", "status": status, "input": "printf fixture",
        "updatedAt": revision, "outputOmitted": !output.isEmpty,
      ]
      let native: JSON = [
        "projection": [
          "thread": ["id": "thread"], "visibleTurnItems": [["item": item]],
        ]
      ]
      var reads = 0
      for _ in 0..<2 {
        let (hydrated, complete) = await client.hydrateToolImages(
          native, threadID: "thread", base: base,
          performRPC: { method, payload in
            #expect(method == "orchestration.getTurnItem")
            #expect(payload["threadId"] as? String == "owner")
            reads += 1
            var detail = item
            detail["output"] = output
            return ["item": detail]
          },
          loadHTML: { _ in throw T3DesktopClient.ClientError.rejected })
        #expect(complete)
        model.apply(T3V2Presentation.detail(hydrated))
        let command = try #require(model.messages.first { $0.toolName == "bash" })
        #expect(command.text == output)
        #expect(command.isRunning == (status == "running"))
        #expect(command.isError == (status == "failed"))
        #expect(command.toolInput == "$ printf fixture")
      }
      #expect(reads == (output.isEmpty ? 0 : 1))
    }
  }

  @Test(arguments: ["running", "completed", "failed"])
  func dynamicToolTextIsNotDiscardedAfterDetailRead(status: String) async throws {
    let client = T3DesktopClient()
    let model = AppModel(continueLastSession: false)
    model.currentSessionPath = "t3:thread"
    defer {
      model.disconnect()
      client.stop()
    }
    let item: JSON = [
      "id": "tool", "threadId": "thread", "type": "dynamic_tool", "runId": "run",
      "toolName": "bash", "input": ["command": "printf fixture"],
      "updatedAt": "revision", "status": status, "outputOmitted": true,
    ]
    let (hydrated, complete) = await client.hydrateToolImages(
      ["projection": ["thread": ["id": "thread"], "visibleTurnItems": [["item": item]]]],
      threadID: "thread", base: URL(string: "http://localhost:12345")!,
      performRPC: { _, _ in
        var detail = item
        detail["output"] = ["content": [["type": "text", "text": "fixture output"]]]
        return ["item": detail]
      },
      loadHTML: { _ in throw T3DesktopClient.ClientError.rejected })
    #expect(complete)
    model.apply(T3V2Presentation.detail(hydrated))
    let command = try #require(model.messages.first { $0.toolName == "bash" })
    #expect(command.text == "fixture output")
    #expect(command.isRunning == (status == "running"))
    #expect(command.isError == (status == "failed"))
  }

  @Test(arguments: ["command_execution", "dynamic_tool"])
  func changingRunningToolsReceiveOutputAcrossBoundedPolls(type: String) async throws {
    let client = T3DesktopClient()
    let model = AppModel(continueLastSession: false)
    model.currentSessionPath = "t3:thread"
    defer {
      model.disconnect()
      client.stop()
    }
    var observed = Set<String>()
    for poll in 0..<3 {
      let items: [JSON] = (0..<17).map { index in
        [
          "id": "command-\(index)", "threadId": "owner", "runId": "run",
          "type": type, "status": "running", "toolName": "bash",
          "input": ["command": "printf \(index)"],
          "updatedAt": "revision-\(poll)", "outputOmitted": true,
        ]
      }
      var reads = 0
      let (hydrated, complete) = await client.hydrateToolImages(
        [
          "projection": [
            "thread": ["id": "thread"], "visibleTurnItems": items.map { ["item": $0] },
          ]
        ],
        threadID: "thread", base: URL(string: "http://localhost:12345")!,
        performRPC: { _, payload in
          reads += 1
          #expect(payload["threadId"] as? String == "owner")
          let id = try #require(payload["itemId"] as? String)
          var detail = try #require(items.first { $0["id"] as? String == id })
          detail["output"] = "output-\(id)"
          return ["item": detail]
        },
        loadHTML: { _ in throw T3DesktopClient.ClientError.rejected })
      #expect(!complete)
      #expect(reads == 8)
      model.apply(T3V2Presentation.detail(hydrated))
      observed.formUnion(model.messages.filter { !$0.text.isEmpty }.map(\.text))
    }
    #expect(observed == Set((0..<17).map { "output-command-\($0)" }))
  }

  @Test func continuationSeparatesOwnersAndWatchScopesAndResetsOnStop() async throws {
    let client = T3DesktopClient()
    defer { client.stop() }
    let items: [JSON] = (0..<9).map { index in
      [
        "id": "shared-item-id", "threadId": "owner-\(index)",
        "type": "command_execution", "status": "running", "input": "printf fixture",
        "updatedAt": "revision", "outputOmitted": true,
      ]
    }
    for (poll, thread, port) in [
      (0, "thread-a", 12345), (1, "thread-b", 12345), (2, "thread-a", 12346),
      (3, "thread-a", 12345), (4, "thread-a", 12345),
    ] {
      if poll == 4 { client.stop() }
      let revisedItems = items.map { item in
        var item = item
        item["updatedAt"] = "revision-\(poll)"
        return item
      }
      var fetchedOwners = Set<String>()
      let (hydrated, complete) = await client.hydrateToolImages(
        ["projection": ["visibleTurnItems": revisedItems.map { ["item": $0] }]],
        threadID: thread, base: URL(string: "http://localhost:\(port)")!,
        performRPC: { _, payload in
          let owner = try #require(payload["threadId"] as? String)
          fetchedOwners.insert(owner)
          var detail = try #require(revisedItems.first { $0["threadId"] as? String == owner })
          detail["output"] = owner
          return ["item": detail]
        },
        loadHTML: { _ in throw T3DesktopClient.ClientError.rejected })
      #expect(!complete)
      if poll == 3 {
        #expect(fetchedOwners == Set((0..<7).map { "owner-\($0)" } + ["owner-8"]))
      } else {
        #expect(fetchedOwners == Set((0..<8).map { "owner-\($0)" }))
      }
      let rows = (hydrated["projection"] as? JSON)?["visibleTurnItems"] as? [JSON] ?? []
      let outputs = rows.compactMap { ($0["item"] as? JSON)?["output"] as? String }
      #expect(outputs.count == 8)
    }
  }

  @Test func unavailableOutputRetriesRatherThanAcknowledgingAnEmptyResult() async throws {
    let client = T3DesktopClient()
    defer { client.stop() }
    let item: JSON = [
      "id": "command", "threadId": "thread", "type": "command_execution",
      "input": "printf fixture", "updatedAt": "revision", "status": "completed",
      "outputOmitted": true,
    ]
    let native: JSON = [
      "projection": ["thread": ["id": "thread"], "visibleTurnItems": [["item": item]]]
    ]
    for attempt in 0..<3 {
      let (_, complete) = await client.hydrateToolImages(
        native, threadID: "thread", base: URL(string: "http://localhost:12345")!,
        performRPC: { _, _ in
          if attempt == 0 { throw T3DesktopClient.ClientError.rejected }
          if attempt == 1 { return ["item": item] }
          var detail = item
          detail["output"] = "recovered"
          return ["item": detail]
        },
        loadHTML: { _ in throw T3DesktopClient.ClientError.rejected })
      #expect(complete == (attempt == 2))
    }
  }
}

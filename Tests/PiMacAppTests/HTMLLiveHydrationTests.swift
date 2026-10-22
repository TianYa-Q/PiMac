import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct HTMLLiveHydrationTests {
  typealias JSON = [String: Any]
  private let base = URL(string: "http://localhost:12345")!
  private let page = T3HTMLRender(
    attachmentID: "fixture-html", title: "Live", height: 200, measurements: [])

  private func item(_ id: String, output: Any?) -> JSON {
    var result: JSON = [
      "type": "dynamic_tool", "id": id, "threadId": "owner",
      "updatedAt": "revision", "status": "completed", "toolName": "mcp__t3-code__html_render",
    ]
    result["output"] = output
    return result
  }

  private func output() -> JSON {
    ["htmlRender": ["attachmentId": page.attachmentID, "title": page.title, "height": 200]]
  }

  private func snapshot(_ items: [JSON]) -> JSON {
    ["projection": ["thread": ["id": "thread"], "visibleTurnItems": items.map { ["item": $0] }]]
  }

  private func rows(_ native: JSON) -> [JSON] {
    ((native["projection"] as? JSON)?["visibleTurnItems"] as? [JSON] ?? [])
      .compactMap { $0["item"] as? JSON }
  }

  @Test func snapshotReferenceDoesNotDependOnDetailAndDownloadsBeforePresentation() async {
    let client = T3DesktopClient()
    let native = snapshot([item("live", output: output())])
    var reads = 0
    var downloads = 0
    let (hydrated, complete) = await client.hydrateToolImages(
      native, threadID: "thread", base: base,
      performRPC: { _, _ in
        reads += 1
        throw T3DesktopClient.ClientError.rejected
      },
      loadHTML: { reference in
        #expect(reference == page)
        downloads += 1
        return "<h1>live</h1>"
      })
    #expect(complete)
    #expect(reads == 0)
    #expect(downloads == 1)
    let messages = (T3V2Presentation.detail(hydrated)["thread"] as? JSON)?["messages"] as? [JSON]
    #expect(messages?.first?["htmlDocument"] as? String == "<h1>live</h1>")
    let (_, cachedComplete) = await client.hydrateToolImages(
      native, threadID: "thread", base: base,
      performRPC: { _, _ in
        Issue.record("Cached item must not fetch detail")
        return [:]
      },
      loadHTML: { _ in
        Issue.record("Cached item must not download again")
        return ""
      })
    #expect(cachedComplete)
  }

  @Test(.timeLimit(.minutes(1)))
  func missingOutputAndDetailFailuresRecoverWithoutReopening() async throws {
    let client = T3DesktopClient()
    let native = snapshot([item("live", output: nil)])
    var reads = 0
    var downloads = 0
    for attempt in 0..<3 {
      let (_, complete) = await client.hydrateToolImages(
        native, threadID: "thread", base: base,
        performRPC: { _, payload in
          reads += 1
          #expect(payload["threadId"] as? String == "owner")
          #expect(payload["revision"] as? String == "revision")
          if attempt == 0 { return ["item": item("live", output: nil)] }
          if attempt == 1 { return ["item": NSNull()] }
          throw T3DesktopClient.ClientError.rejected
        },
        loadHTML: { _ in
          downloads += 1
          return "unexpected"
        })
      #expect(!complete)
    }
    #expect(reads == 3)
    #expect(downloads == 0)
    let (_, coolingDown) = await client.hydrateToolImages(
      native, threadID: "thread", base: base,
      performRPC: { _, _ in
        Issue.record("Failure retry should be throttled")
        return [:]
      },
      loadHTML: { _ in "unexpected" })
    #expect(!coolingDown)
    try await Task.sleep(for: .seconds(10.1))
    let (hydrated, complete) = await client.hydrateToolImages(
      native, threadID: "thread", base: base,
      performRPC: { _, _ in ["item": item("live", output: output())] },
      loadHTML: { _ in "<h1>recovered</h1>" })
    #expect(complete)
    #expect(rows(hydrated).first?["htmlDocument"] as? String == "<h1>recovered</h1>")
  }

  @Test func readBudgetContinuesAcrossPollsAndValidFailureIsNotMissingOutput() async {
    let client = T3DesktopClient()
    let native = snapshot((0..<10).map { item("page-\($0)", output: nil) })
    var reads = 0
    var downloads = 0
    for expectedComplete in [false, true] {
      let (hydrated, complete) = await client.hydrateToolImages(
        native, threadID: "thread", base: base,
        performRPC: { _, payload in
          reads += 1
          let id = payload["itemId"] as? String ?? ""
          return ["item": item(id, output: id == "page-9" ? ["isError": true] : output())]
        },
        loadHTML: { _ in
          downloads += 1
          return "<h1>page</h1>"
        })
      #expect(complete == expectedComplete)
      if !expectedComplete {
        #expect(reads == 8)
      } else {
        #expect(rows(hydrated).filter { $0["htmlDocument"] is String }.count == 9)
      }
    }
    #expect(reads == 10)
    #expect(downloads == 9)
  }

  @Test(arguments: [false, true])
  func failedDownloadRetainsDetailReferenceForNextPoll(outputOmitted: Bool) async {
    let client = T3DesktopClient()
    defer { client.stop() }
    var omittedItem = item("live", output: nil)
    omittedItem["outputOmitted"] = outputOmitted
    let native = snapshot([omittedItem])
    var reads = 0
    let (_, firstComplete) = await client.hydrateToolImages(
      native, threadID: "thread", base: base,
      performRPC: { _, _ in
        reads += 1
        return ["item": item("live", output: output())]
      },
      loadHTML: { _ in throw T3DesktopClient.ClientError.rejected })
    #expect(!firstComplete)
    let (hydrated, complete) = await client.hydrateToolImages(
      native, threadID: "thread", base: base,
      performRPC: { _, _ in
        reads += 1
        throw T3DesktopClient.ClientError.rejected
      },
      loadHTML: { _ in "<h1>retried</h1>" })
    #expect(complete)
    #expect(reads == 1)
    #expect(rows(hydrated).first?["htmlDocument"] as? String == "<h1>retried</h1>")
    #expect(rows(hydrated).first?["output"] as? JSON != nil)
    let (_, cachedComplete) = await client.hydrateToolImages(
      native, threadID: "thread", base: base,
      performRPC: { _, _ in
        Issue.record("Recovered HTML must use its cached detail")
        return [:]
      },
      loadHTML: { _ in
        Issue.record("Recovered HTML must not download again")
        return ""
      })
    #expect(cachedComplete)
  }
}

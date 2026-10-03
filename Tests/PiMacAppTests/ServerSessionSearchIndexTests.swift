import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ServerSessionSearchIndexTests {
  @Test func cacheInvalidatesOnUpdatesAndResetAndTitleMatchesAvoidReads() async throws {
    let index = ServerSessionSearchIndex()
    let session = SessionItem(path: "t3:one", title: "项目", modifiedAt: .now)
    var calls = 0
    func load(_ id: String) async throws -> [String] {
      #expect(id == "one")
      calls += 1
      return ["正文关键字"]
    }
    #expect(try await index.messages(for: "项目", in: [session], load: load).isEmpty)
    #expect(calls == 0)
    let first = try await index.messages(for: "关键字", in: [session], load: load)
    #expect(SessionSearch.results(for: "项目 关键字", in: [session], messagesByPath: first).count == 1)
    _ = try await index.messages(for: "正文", in: [session], load: load)
    #expect(calls == 1)
    // Negative terms require content even when the title matches.
    _ = try await index.messages(for: "项目 -秘密", in: [session], load: load)
    #expect(calls == 1)
    let updated = SessionItem(
      path: session.path, title: session.title,
      modifiedAt: session.modifiedAt.addingTimeInterval(1))
    _ = try await index.messages(for: "正文", in: [updated], load: load)
    #expect(calls == 2)
    index.reset()
    _ = try await index.messages(for: "正文", in: [updated], load: load)
    #expect(calls == 3)
  }

  @Test func failedAndInvalidatedLoadsNeverBecomeEmptyCachedResults() async throws {
    let index = ServerSessionSearchIndex()
    let session = SessionItem(path: "t3:one", title: "项目", modifiedAt: .now)
    do {
      _ = try await index.messages(for: "正文", in: [session]) { _ in
        throw URLError(.notConnectedToInternet)
      }
      Issue.record("Expected failed load")
    } catch {}
    do {
      _ = try await index.messages(for: "正文", in: [session]) { _ in
        index.reset()
        return ["旧连接"]
      }
      Issue.record("Expected generation cancellation")
    } catch is CancellationError {}
    let result = try await index.messages(for: "正文", in: [session]) { _ in ["最新正文"] }
    #expect(result[session.path] == ["最新正文"])
  }
}

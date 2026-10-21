import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ServerSessionSearchIndexTests {
  @Test func scopedQueriesSkipRejectedTitlesAndTitleOnlyQueriesNeedNoServer() async throws {
    let index = ServerSessionSearchIndex()
    let sessions = [
      SessionItem(path: "t3:one", title: "库存", modifiedAt: .now),
      SessionItem(path: "t3:two", title: "其他", modifiedAt: .now),
    ]
    var calls: [String] = []
    func load(_ id: String) async throws -> [String] {
      calls.append(id)
      return ["正文"]
    }
    #expect(try await index.messages(for: "title:库存", in: sessions, load: load).isEmpty)
    #expect(try await index.messages(for: "-title:库存", in: sessions, load: load).isEmpty)
    #expect(calls.isEmpty)
    let result = try await index.messages(for: "title:库存 text:正文", in: sessions, load: load)
    #expect(calls == ["one"])
    #expect(result["t3:one"] == ["正文"])
  }

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
    let repeated = try await index.messages(for: "正文", in: [session], load: load)
    #expect(repeated[session.path] == ["正文关键字"])
    // NSCache 可在内存压力下自动淘汰；合法的重新读取不能判为业务失败。
    #expect(calls >= 1)
    // 即使标题匹配，排除词也必须能够读取正文。
    let excluded = try await index.messages(for: "项目 -秘密", in: [session], load: load)
    #expect(excluded[session.path] == ["正文关键字"])
    let updated = SessionItem(
      path: session.path, title: session.title,
      modifiedAt: session.modifiedAt.addingTimeInterval(1))
    let beforeUpdate = calls
    _ = try await index.messages(for: "正文", in: [updated], load: load)
    #expect(calls == beforeUpdate + 1)
    index.reset()
    let beforeResetRead = calls
    _ = try await index.messages(for: "正文", in: [updated], load: load)
    #expect(calls == beforeResetRead + 1)
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

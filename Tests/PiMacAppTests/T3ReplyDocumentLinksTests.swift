import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3ReplyDocumentLinksTests {
  @Test(.timeLimit(.minutes(2)))
  func officialServerDownloadsChineseDocumentFromThreadWorktree() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/reply-links-upstream/server-\(UUID())")
    let worktree = root.appendingPathComponent("worktree")
    let document = worktree.appendingPathComponent("tmp/security-129/处置报告-待上线核验稿.docx")
    try FileManager.default.createDirectory(
      at: document.deletingLastPathComponent(), withIntermediateDirectories: true)
    let expected = Data("document download fixture".utf8)
    try expected.write(to: document)
    let binary = root.appendingPathComponent("fixture-pi")
    let fixture = repository.appendingPathComponent("sidecars/t3-server/tests/fixtures/pi.mjs")
    try "#!/bin/sh\nexec node \"\(fixture.path)\" \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "reply-document-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults, stateDirectory: root)
    let client = T3DesktopClient(defaults: defaults)
    defer {
      client.stop()
      service.stop()
      workspace.disconnectAll()
      defaults.removePersistentDomain(forName: suite)
    }
    try startT3ProtocolFixture(
      service: service, workspace: workspace, stateDirectory: root, binary: binary,
      model: "test/model")
    client.start(service: service)
    try await client.waitUntilReady()
    let projectID = try await client.ensureProject(root)
    let threadID = UUID().uuidString
    try await client.dispatch([
      "type": "thread.create", "threadId": threadID, "projectId": projectID, "title": "File links",
      "modelSelection": ["instanceId": "pi", "model": "test/model"],
      "runtimeMode": "full-access", "interactionMode": "default", "branch": NSNull(),
      "worktreePath": worktree.path,
    ])
    let href = try #require(
      "tmp/security-129/处置报告-待上线核验稿.docx"
        .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
    // 文件仅存在于线程 worktree：相对路径必须由 Server 按权威线程状态解析。
    let url = try await client.replyDocumentURL(href: href, threadID: threadID)
    let (data, response) = try await URLSession.shared.data(from: url)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(http.value(forHTTPHeaderField: "Content-Disposition")?.hasPrefix("attachment;") == true)
    #expect(data == expected)
    await #expect(throws: Error.self) {
      try await client.replyDocumentURL(
        href: "tmp/security-129/missing.docx", threadID: threadID)
    }
  }

  @Test func nativeAdapterOnlyAcceptsLocalReferences() throws {
    for target in ["report.docx", "tmp/report%20name.docx", "file:///tmp/report.htm#section"] {
      #expect(T3ReplyDocumentLinks.href(for: try #require(URL(string: target))) != nil)
    }
    for target in [
      "https://example.com/report.docx", "file://host/report.docx", "//host/report.docx",
      "javascript:report.html", "report.html?x=1",
    ] {
      #expect(T3ReplyDocumentLinks.href(for: try #require(URL(string: target))) == nil)
    }
  }

  @Test func officialParserHandlesEncodedChineseAndPreservesPreviewBehavior() async throws {
    let runtime = T3StreamReducer(kind: .shell)
    let target =
      "tmp/security-129/%E5%A4%84%E7%BD%AE%E6%8A%A5%E5%91%8A-%E5%89%91%E5%B3%B0%E5%85%AC%E5%8F%B8-129%E5%8F%B7-%E5%BE%85%E4%B8%8A%E7%BA%BF%E6%A0%B8%E9%AA%8C%E7%A8%BF.docx"
    for (href, path, download) in [
      (target, "./tmp/security-129/处置报告-剑峰公司-129号-待上线核验稿.docx", true),
      ("reports/report.XLSX", "./reports/report.XLSX", true),
      ("reports/README", "./reports/README", true),
      ("reports/literal%2520name.docx", "./reports/literal%20name.docx", true),
      ("file:///tmp/report%20name.docx", "/tmp/report name.docx", true),
      ("reports/report.HTML#section", "./reports/report.HTML", false),
      ("/tmp/report.PDF", "/tmp/report.PDF", false),
      ("src/main.swift:12:3", "./src/main.swift", true),
    ] {
      let markdown = try AttributedString(markdown: "[文件](\(href))")
      let url = try #require(markdown.runs.compactMap(\.link).first)
      let nativeHref = try #require(T3ReplyDocumentLinks.href(for: url))
      let resource = try await runtime.prepare(
        .prepareReplyDocument,
        input: ImmutableJSONSnapshot(value: [
          "href": nativeHref, "threadId": "thread-1",
        ])
      ).value
      #expect(resource["_tag"] as? String == "media-file")
      #expect(resource["threadId"] as? String == "thread-1")
      #expect(resource["path"] as? String == path)
      #expect(resource["disposition"] as? String == (download ? "attachment" : nil))
    }
    for href in [
      "#section", "reports/", "a%00.docx", String(repeating: "a", count: 1025) + ".docx",
    ] {
      await #expect(throws: T3StreamReducer.Failure.self) {
        try await runtime.prepare(
          .prepareReplyDocument,
          input: ImmutableJSONSnapshot(value: [
            "href": href, "threadId": "thread-1",
          ]))
      }
    }
  }
}

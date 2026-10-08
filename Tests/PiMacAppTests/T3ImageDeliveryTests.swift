import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3ImageDeliveryTests {
  @Test func imageLinkParsingIsExplicitAndBounded() {
    #expect(
      T3ReplyImageLinks.paths(in: "[高清图](images/a.png) ![图](<images/b c.jpg>) [重复](images/a.png)")
        == ["images/a.png", "images/b c.jpg"])
    #expect(
      T3ReplyImageLinks.paths(
        in:
          "[remote](https://example.com/a.png) [bad](javascript:a.png) `![example](a.png)`\n```\n[code](b.png)\n```"
      ).isEmpty)
    #expect(T3ReplyImageLinks.paths(in: "[图](file:///tmp/a%20b.png)") == ["/tmp/a b.png"])
    #expect(
      T3ReplyImageLinks.paths(in: (0..<20).map { "[图](\($0).png)" }.joined(separator: " ")).count
        == 8)
  }

  @Test func directImagesPreserveOfficialIndexOrder() {
    let blocks: [[String: Any]] = [
      ["type": "text", "text": "hello"],
      ["type": "image", "mimeType": "image/png"],
      ["type": "image", "mimeType": "image/svg+xml"],
      ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg"]],
      ["type": "image", "source": ["type": "url", "media_type": "image/png"]],
    ]
    #expect(T3ToolOutputImages.mimeTypes(blocks) == ["image/png", "image/jpeg"])
    #expect(T3ToolOutputImages.mimeTypes(["content": blocks]) == ["image/png", "image/jpeg"])
    #expect(T3ToolOutputImages.mimeTypes(blocks[1]) == ["image/png"])
    #expect(T3ToolOutputImages.mimeTypes(nil).isEmpty)
    #expect(T3ToolOutputImages.mimeTypes(Array(repeating: blocks[1], count: 100)).count == 8)
  }

  @Test(.timeLimit(.minutes(1)))
  func desktopReceivesFileLinksAndDirectImagesFromOfficialServer() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = try #require(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jL1cAAAAASUVORK5CYII="
      ))
    try bytes.write(to: root.appendingPathComponent("comparison.png"))
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = repository.appendingPathComponent("sidecars/t3-server/tests/fixtures/pi.mjs")
    let binary = root.appendingPathComponent("fixture-pi")
    try "#!/bin/sh\nexec node \"\(fixture.path)\" \"$@\"\n".write(
      to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let suite = "pimac-images-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(binary.path, forKey: "piPath")
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults)
    let client = T3DesktopClient(defaults: defaults)
    defer {
      client.stop()
      service.stop()
      workspace.disconnectAll()
    }
    try service.start(
      workspace: workspace, token: T3NetworkEndpoint.secret(),
      stateDirectory: root.appendingPathComponent("state"))
    client.start(service: service)
    try await client.waitUntilReady()
    let projectID = try await client.ensureProject(root)
    let threadID = UUID().uuidString
    try await client.dispatch([
      "type": "thread.create", "threadId": threadID, "projectId": projectID,
      "title": "Images", "modelSelection": ["instanceId": "pi", "model": "test/model"],
      "runtimeMode": "full-access", "interactionMode": "default", "branch": NSNull(),
      "worktreePath": NSNull(),
    ])
    var latest: [String: Any] = [:]
    client.watch(threadID, owner: UUID()) { latest = $0 }
    for (prompt, expectedCount) in [("[查看高清对比图](comparison.png)", 1), ("tool-image", 2)] {
      try await client.dispatch([
        "type": "message.dispatch", "threadId": threadID, "messageId": UUID().uuidString,
        "text": prompt, "attachments": [], "dispatchMode": ["type": "start_immediately"],
      ])
      var images: [PromptAttachment] = []
      for _ in 0..<200 {
        let thread = latest["thread"] as? [String: Any]
        images = (thread?["messages"] as? [[String: Any]] ?? []).filter {
          $0["role"] as? String == "assistant"
        }.flatMap { $0["localImages"] as? [PromptAttachment] ?? [] }
        if images.count >= expectedCount { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      #expect(images.count == expectedCount)
      for image in images { #expect(try Data(contentsOf: image.url) == bytes) }
    }
    let preview = try await client.replyImage(path: "comparison.png", threadID: threadID)
    #expect(try Data(contentsOf: preview.url) == bytes)
    await #expect(throws: (any Error).self) {
      try await client.replyImage(path: "missing.png", threadID: threadID)
    }
  }
}

import Foundation
import Testing

@testable import PiMacApp

struct SessionDiscoveryCacheTests {
  @Test
  func reusesUnchangedFilesAndInvalidatesAppends() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("session-cache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("session.jsonl")
    try Data("header\n".utf8).write(to: url)
    let cache = SessionDiscoveryCache()
    var loads = 0
    func read(project: String = "/project") -> SessionItem? {
      cache.item(at: URL(fileURLWithPath: url.path), project: project) {
        loads += 1
        return SessionItem(path: url.path, title: "load \(loads)", modifiedAt: .distantPast)
      }
    }
    #expect(read()?.title == "load 1")
    #expect(read()?.title == "load 1")
    #expect(loads == 1)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("user message\n".utf8))
    try handle.close()
    #expect(read()?.title == "load 2")
    #expect(read(project: "/other")?.title == "load 3")
    try FileManager.default.removeItem(at: url)
    #expect(read() == nil)
    #expect(loads == 3)
  }

  @Test
  func ignoresResourceMetadataCachedOnCallerURL() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("session-cache-url-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("session.jsonl")
    try Data("header\n".utf8).write(to: url)
    // Directory enumeration and earlier callers may have populated URL resource caches.
    _ = try url.resourceValues(forKeys: [
      .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
    ])
    let cache = SessionDiscoveryCache()
    var loads = 0
    func read() -> SessionItem? {
      cache.item(at: url, project: "/project") {
        loads += 1
        return SessionItem(path: url.path, title: "load \(loads)", modifiedAt: .distantPast)
      }
    }
    #expect(read()?.title == "load 1")
    #expect(read()?.title == "load 1")
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("new message\n".utf8))
    try handle.close()
    #expect(read()?.title == "load 2")
    #expect(read()?.title == "load 2")
    #expect(loads == 2)
    try FileManager.default.removeItem(at: url)
    #expect(read() == nil)
  }

  @Test
  func cachesDraftsButDiscoversThemAfterTheyChange() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("session-cache-draft-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("draft.jsonl")
    let project = root.standardizedFileURL.path
    let header: [String: Any] = ["type": "session", "cwd": project]
    var data = try JSONSerialization.data(withJSONObject: header)
    data.append(0x0A)
    try data.write(to: url)
    #expect(AppModel.discoverSessions(for: project, root: root).isEmpty)
    #expect(AppModel.discoverSessions(for: project, root: root).isEmpty)
    let message: [String: Any] = [
      "type": "message", "timestamp": "2026-01-02T10:00:00Z",
      "message": ["role": "user", "content": [["type": "text", "text": "新增会话"]]],
    ]
    data.append(try JSONSerialization.data(withJSONObject: message))
    data.append(0x0A)
    try data.write(to: url)
    #expect(AppModel.discoverSessions(for: project, root: root).first?.title == "新增会话")
    try FileManager.default.removeItem(at: url)
    #expect(AppModel.discoverSessions(for: project, root: root).isEmpty)
  }
}

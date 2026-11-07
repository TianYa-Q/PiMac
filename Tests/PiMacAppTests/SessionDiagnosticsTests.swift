import Foundation
import Testing

@testable import PiMacApp

struct SessionDiagnosticsTests {
  @Test
  func preservesCompletePayloadAndRawErrorInPrivateLog() throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/session-diagnostics-tests/\(UUID().uuidString)")
    let file = directory.appendingPathComponent("diagnostics.log")
    let payload = String(repeating: "原始正文🧪", count: 20000)
    let error = NSError(
      domain: NSURLErrorDomain, code: -1001,
      userInfo: [
        NSURLErrorFailingURLStringErrorKey: "http://127.0.0.1:1234/api/orchestration/threads/id",
        "raw": "original network error",
      ])
    try SessionDiagnostics.append(
      "http.failure", id: "request-1",
      fields: [
        "payload": payload, "headers": ["Authorization": "Bearer test-credential"],
        "error": SessionDiagnostics.errorFields(error),
      ], destination: file)
    let data = try Data(contentsOf: file)
    let entry = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let fields = try #require(entry["fields"] as? [String: Any])
    #expect(fields["payload"] as? String == payload)
    #expect((fields["headers"] as? [String: String])?["Authorization"] == "Bearer test-credential")
    let raw = try #require(fields["error"] as? [String: Any])
    #expect(raw["code"] as? Int == -1001)
    #expect((raw["userInfo"] as? String)?.contains("original network error") == true)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try SessionDiagnostics.append("next", id: "request-1", fields: [:], destination: file)
    #expect(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count == 2)
  }

  @Test func rotationBoundsFilesAndKeepsCompleteNewestEntries() throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/session-diagnostics-tests/\(UUID().uuidString)")
    let file = directory.appendingPathComponent("diagnostics.log")
    for index in 0..<12 {
      try SessionDiagnostics.append(
        "event", id: "\(index)", fields: ["payload": String(repeating: "x", count: 250)],
        destination: file, maxFileBytes: 512, maxArchives: 2)
    }
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    #expect(files.count == 3)
    for item in files {
      let data = try Data(contentsOf: item)
      #expect(data.count <= 512)
      #expect(try JSONSerialization.jsonObject(with: data) is [String: Any])
    }
    let current = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(current["id"] as? String == "11")
  }

  @Test func startupPrunesLegacyArchivesByByteBudgetWithoutTouchingUnrelatedFiles() throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/session-diagnostics-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("diagnostics.log")
    let oversized = file.appendingPathExtension(UUID().uuidString)
    try Data(repeating: 120, count: 2048).write(to: oversized)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oversized.path)
    let unrelated = file.appendingPathExtension("manual-backup")
    try Data("keep".utf8).write(to: unrelated)
    try SessionDiagnostics.append(
      "event", id: "id", fields: [:], destination: file, maxFileBytes: 512, maxArchives: 2)
    #expect(!FileManager.default.fileExists(atPath: oversized.path))
    #expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep")
    let before = try Data(contentsOf: file)
    #expect(throws: (any Error).self) {
      try SessionDiagnostics.append(
        "large", id: "id", fields: ["body": String(repeating: "x", count: 1024)],
        destination: file, maxFileBytes: 512, maxArchives: 2)
    }
    #expect(try Data(contentsOf: file) == before)
    try SessionDiagnostics.append(
      "next", id: "id", fields: [:], destination: file, maxFileBytes: 512, maxArchives: 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
  }

  @Test func refusesArchiveSymlinkWithoutFollowingIt() throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/session-diagnostics-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent("target")
    try Data("untouched".utf8).write(to: target)
    let file = directory.appendingPathComponent("diagnostics.log")
    try FileManager.default.createSymbolicLink(
      at: file.appendingPathExtension(UUID().uuidString), withDestinationURL: target)
    #expect(throws: (any Error).self) {
      try SessionDiagnostics.append("event", id: "id", fields: [:], destination: file)
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
  }

  @Test
  func refusesSymlinkWithoutChangingTarget() throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/session-diagnostics-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent("target")
    try Data("untouched".utf8).write(to: target)
    let link = directory.appendingPathComponent("diagnostics.log")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: (any Error).self) {
      try SessionDiagnostics.append("event", id: "id", fields: [:], destination: link)
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
  }
}

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

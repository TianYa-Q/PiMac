import Foundation
import Testing

@testable import PiMacApp

struct T3UpdateRestartTests {
  @Test func markerUsesOfficialServerPathAndRefreshesOnEachUpdate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = root.appendingPathComponent("server-owned")
    try FileManager.default.createDirectory(
      at: server, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let marker = server.appendingPathComponent("runtime/desktop-update-restart")
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    try T3UpdateRestart.prepare(in: root)
    #expect(FileManager.default.fileExists(atPath: marker.path))
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: marker.path)
    try T3UpdateRestart.prepare(in: root)
    let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(Date.now.timeIntervalSince(try #require(attributes[.modificationDate] as? Date)) < 5)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime").path))
  }

  @Test func markerNeverFollowsSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = root.appendingPathComponent("server-owned/runtime")
    try FileManager.default.createDirectory(
      at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let target = root.appendingPathComponent("target")
    try Data("untouched".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: runtime.appendingPathComponent("desktop-update-restart"), withDestinationURL: target)
    #expect(throws: (any Error).self) { try T3UpdateRestart.prepare(in: root) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
  }

  @Test func runtimeDirectoryNeverFollowsSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = root.appendingPathComponent("server-owned")
    let target = root.appendingPathComponent("target")
    for directory in [server, target] {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    try FileManager.default.createSymbolicLink(
      at: server.appendingPathComponent("runtime"), withDestinationURL: target)
    #expect(throws: (any Error).self) { try T3UpdateRestart.prepare(in: root) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
  }
}

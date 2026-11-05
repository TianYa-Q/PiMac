import Foundation
import Testing

@testable import PiMacApp

struct VersionManagerTests {
  @Test func comparesVersionsEvenWhenInternallyPinned() {
    let item = ManagedExtension(
      source: "pi-web-access", path: "", scope: "内部管理",
      kind: .npm(name: "pi-web-access", pinned: true), currentVersion: "0.41.0",
      latestVersion: "0.47.0")
    #expect(item.hasUpdate)
    #expect(!VersionManagerModel.isNewer("1.5.0", than: "1.5.0"))
    #expect(VersionManagerModel.isNewer("1.10.0", than: "1.5.0"))
    #expect(!VersionManagerModel.isNewer("1.3.0", than: "1.5.0"))
  }

  @Test func installedInventoryChecksRealFilesAndRejectsMissingCorruptOrMismatchedVersions() throws
  {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/managed-modules/inventory-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let package = root.appendingPathComponent("package.json")
    try Data(#"{"version":"1.5.0"}"#.utf8).write(to: package)
    let receipt = root.appendingPathComponent("modules.json")
    let payload: [String: Any] = [
      "schemaVersion": 1, "executable": "/usr/bin/true",
      "modules": [
        [
          "name": "@earendil-works/pi-coding-agent", "version": "1.5.0",
          "manifestPath": package.path,
        ]
      ],
    ]
    try JSONSerialization.data(withJSONObject: payload).write(to: receipt)
    #expect(try ManagedPiRuntime.load(from: receipt).modules.first?.version == "1.5.0")
    try Data(#"{"version":"1.3.0"}"#.utf8).write(to: package)
    #expect(throws: Error.self) { try ManagedPiRuntime.load(from: receipt) }
    try Data("broken".utf8).write(to: receipt)
    #expect(throws: Error.self) { try ManagedPiRuntime.load(from: receipt) }
    #expect(throws: Error.self) {
      try ManagedPiRuntime.load(from: root.appendingPathComponent("missing.json"))
    }
  }
}

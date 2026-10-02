import Darwin
import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3LifecycleTests {
  @Test(.timeLimit(.minutes(1)))
  func killedServerCanRestartWithoutManualMarkerRemoval() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(stateDirectory: root)
    defer { service.stop(); workspace.disconnectAll() }
    let marker = root.appendingPathComponent("child-owner.json")
    func ownerPID() throws -> Int32 {
      let data = try Data(contentsOf: marker)
      let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      return Int32(try #require(record["pid"] as? Int))
    }
    try service.start(workspace: workspace, token: T3NetworkEndpoint.secret())
    for _ in 0..<200 where service.serverURL == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    _ = try #require(service.serverURL)
    let firstPID = try ownerPID()
    #expect(!T3BridgeStateLease.isAvailable(root.appendingPathComponent("child-owner.lock")))
    #expect(kill(firstPID, SIGKILL) == 0)
    for _ in 0..<200 where service.serverURL != nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await service.stopAndWait())
    #expect(FileManager.default.fileExists(atPath: marker.path))
    try service.start(workspace: workspace, token: T3NetworkEndpoint.secret())
    for _ in 0..<200 where service.serverURL == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    _ = try #require(service.serverURL)
    #expect(try ownerPID() != firstPID)
    // Reload first disconnects the workspace, then awaits the shutdown barrier.
    // Repeated stop requests must preserve the in-flight process tracking.
    service.stop()
    service.stop()
    #expect(await service.stopAndWait())
    #expect(await service.stopAndWait())
    #expect(!service.isStopping)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(T3BridgeStateLease.isAvailable(root.appendingPathComponent("child-owner.lock")))
  }

  @Test func childLeaseProbeNeverFollowsSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("child-owner.lock")
    #expect(T3BridgeStateLease.isAvailable(file))
    let target = root.appendingPathComponent("target")
    try Data().write(to: target)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    #expect(!T3BridgeStateLease.isAvailable(file))
  }
}

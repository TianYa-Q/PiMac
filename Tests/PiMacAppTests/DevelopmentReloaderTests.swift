import Combine
import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct DevelopmentReloaderTests {
  @Test func unchangedChecksKeepHeartbeatWithoutInvalidatingWorkspace() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/idle-cpu-fix/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
    let heartbeat = root.appendingPathComponent("heartbeat.json")
    let request = root.appendingPathComponent("request")
    let executable = try #require(Bundle.main.executableURL)
    let reloader = DevelopmentReloader(environment: [
      "PIMAC_DEV_RELOAD_PATH": executable.path,
      "PIMAC_DEV_STATE_PATH": heartbeat.path,
      "PIMAC_DEV_REQUEST_PATH": request.path,
    ])
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let delegate = AppDelegate()
    var updates = 0
    let observation = workspace.objectWillChange.sink { updates += 1 }
    defer { observation.cancel() }

    reloader.check(workspace: workspace, appDelegate: delegate)
    let firstHeartbeat = try Data(contentsOf: heartbeat)
    for _ in 0..<5 { reloader.check(workspace: workspace, appDelegate: delegate) }
    #expect(updates == 0)
    #expect(workspace.developmentReloadStatus.isEmpty)
    let lastHeartbeat = try Data(contentsOf: heartbeat)
    #expect(firstHeartbeat != lastHeartbeat)
    let state = try #require(JSONSerialization.jsonObject(with: lastHeartbeat) as? [String: Any])
    #expect(state["phase"] as? String == "watching")
    #expect(state["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier))

    // 新构建请求仍要显示；重复检查不能继续广播同一状态，也不能丢失心跳。
    try Data().write(to: request)
    reloader.check(workspace: workspace, appDelegate: delegate)
    #expect(!workspace.developmentReloadStatus.isEmpty)
    #expect(updates == 1)
    for _ in 0..<5 { reloader.check(workspace: workspace, appDelegate: delegate) }
    #expect(updates == 1)
    try FileManager.default.trashItem(at: request, resultingItemURL: nil)
    reloader.check(workspace: workspace, appDelegate: delegate)
    #expect(workspace.developmentReloadStatus.isEmpty)
    #expect(updates == 2)
  }
}

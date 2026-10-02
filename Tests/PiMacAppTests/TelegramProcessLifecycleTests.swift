import Foundation
import XCTest

@testable import PiMacApp

@MainActor
final class TelegramProcessLifecycleTests: XCTestCase {
  func testRemoteStartupSurvivesDesktopIdleCollectionAndAcceptsPrompt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("fake-pi")
    try """
    #!/usr/bin/python3
    import sys,json
    for line in sys.stdin:
        cmd=json.loads(line)
        data={'models': [], 'messages': [], 'disposition': 'handled'}
        print(json.dumps({'type':'response','id':cmd['id'],'command':cmd['type'],'success':True,'data':data}),flush=True)
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let previousPiPath = UserDefaults.standard.object(forKey: "piPath")
    UserDefaults.standard.set(script.path, forKey: "piPath")
    defer { UserDefaults.standard.set(previousPiPath, forKey: "piPath") }
    let suite = "PiMac.TelegramLifecycle.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let telegram = TelegramControl(defaults: defaults)
    let workspace = WorkspaceModel(telegram: telegram)
    defer { workspace.disconnectAll() }
    let selection = workspace.selectedTabID
    let remote = try XCTUnwrap(
      telegram.selectProject(WorkspaceProject(url: root), in: workspace))

    // Startup emits loading -> idle before Telegram submits its first prompt.
    // Desktop background collection must not kill that newly ready RPC process.
    await TelegramControl.waitForSessionStatus(in: remote, timeout: 5)
    XCTAssertEqual(remote.connectionState, .connected)
    try await Task.sleep(for: .milliseconds(100))
    workspace.remoteSelectionChanged()
    XCTAssertEqual(workspace.selectedTabID, selection)
    XCTAssertTrue(remote.isProcessRunning)
    XCTAssertTrue(remote.clientConnectedForCommands)
    let accepted = await withCheckedContinuation { continuation in
      remote.sendRemotePrompt("regression check") { continuation.resume(returning: $0) }
    }
    XCTAssertTrue(accepted)

    // The protection is selective: genuinely idle, unowned background processes
    // must still be reclaimed instead of keeping every historical conversation alive.
    let cold = workspace.taskModel(
      in: root, sessionPath: root.appendingPathComponent("cold.jsonl").path)
    await TelegramControl.waitForSessionStatus(in: cold, timeout: 5)
    try await Task.sleep(for: .milliseconds(100))
    workspace.remoteSelectionChanged()
    XCTAssertFalse(telegram.keepsProcessWarm(cold))
    XCTAssertFalse(cold.isProcessRunning)
    XCTAssertTrue(remote.isProcessRunning)
  }
}

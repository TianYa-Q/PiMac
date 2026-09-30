import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct PiRPCClientTests {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = root.appendingPathComponent("fake-pi")
    try """
    #!/usr/bin/python3
    import sys,json,time
    for line in sys.stdin:
        cmd=json.loads(line)
        if cmd['type']=='silent': continue
        if cmd['type']=='late': time.sleep(0.2)
        print(json.dumps({'type':'response','id':cmd['id'],'command':cmd['type'],'success':True,'data':{'disposition':'handled'}}),flush=True)
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  @Test func handledInputReleasesAppWaitingStateWithoutAgentEvents() async throws {
    let script = try fixture()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let client = PiRPCClient()
    defer { client.stop() }
    try client.start(
      piPath: script.path, workingDirectory: script.deletingLastPathComponent(),
      continueLastSession: false)
    let app = AppModel(restoreLastProjectOnLaunch: false, rpcClient: client)
    app.connectionState = .connected
    let accepted: Bool = await withCheckedContinuation { continuation in
      app.sendRemotePrompt("/handled") { continuation.resume(returning: $0) }
      #expect(app.awaitingAgentStart)
      #expect(!app.canRestartSafely)
    }
    #expect(accepted)
    #expect(!app.awaitingAgentStart)
    #expect(app.canRestartSafely)
    #expect(!app.isBusy)
  }

  @Test func defaultDeadlinesOnlyApplyToInspectionCommands() {
    #expect(PiRPCClient.defaultTimeout(for: "get_state") == 30)
    for name in [
      "prompt", "steer", "follow_up", "compact", "abort", "switch_session", "extension_ui_response",
    ] {
      #expect(PiRPCClient.defaultTimeout(for: name) == nil)
    }
  }

  @Test func timeoutAndLateResponseCompleteExactlyOnce() async throws {
    let script = try fixture()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let client = PiRPCClient()
    defer { client.stop() }
    try client.start(
      piPath: script.path, workingDirectory: script.deletingLastPathComponent(),
      continueLastSession: false)
    // Wait for the login shell and fixture startup before testing an actual late response.
    let ready: Bool = await withCheckedContinuation { continuation in
      client.request(["type": "get_state"], timeout: 5) { result in
        if case .success = result {
          continuation.resume(returning: true)
        } else {
          continuation.resume(returning: false)
        }
      }
    }
    #expect(ready)
    var count = 0
    var timedOut = false
    client.request(["type": "late"], timeout: 0.03) { result in
      count += 1
      if case .failure(let error) = result, case RPCError.timedOut("late") = error {
        timedOut = true
      }
    }
    try await Task.sleep(for: .milliseconds(400))
    #expect(timedOut)
    #expect(count == 1)
    #expect(client.pendingRequestSummary.isEmpty)
  }

  @Test func stoppingCancelsPendingRequestsAndSupportsReentrantCallbacks() throws {
    let script = try fixture()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let client = PiRPCClient()
    try client.start(
      piPath: script.path, workingDirectory: script.deletingLastPathComponent(),
      continueLastSession: false)
    var cancellations = 0
    client.request(["type": "silent"]) { result in
      if case .failure(let error) = result, case RPCError.cancelled = error { cancellations += 1 }
      client.request(["type": "get_state"]) { result in
        if case .failure(let error) = result, case RPCError.notRunning = error {
          cancellations += 1
        }
      }
    }
    client.stop()
    client.stop()
    #expect(cancellations == 2)
    #expect(client.pendingRequestSummary.isEmpty)
    #expect(!client.isRunning)
  }
}

import Foundation
import XCTest

@testable import PiMacApp

@MainActor
final class T3WorkspaceCommandsTests: XCTestCase {
  func testHistoricalSendStartsOneWriterPreservesSelectionAndDeduplicates() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("session.jsonl")
    let records: [[String: Any]] = [
      ["type": "session", "cwd": root.path, "id": "session"],
      ["type": "message", "id": "u", "message": ["role": "user", "content": "old"]],
    ]
    var data = Data()
    for record in records {
      data.append(try JSONSerialization.data(withJSONObject: record))
      data.append(10)
    }
    try data.write(to: session)
    let script = root.appendingPathComponent("fake-pi")
    let log = root.appendingPathComponent("prompts.jsonl")
    try """
    #!/usr/bin/python3
    import sys,json
    session=\(String(data: try JSONSerialization.data(withJSONObject: session.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!)
    log=\(String(data: try JSONSerialization.data(withJSONObject: log.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!)
    for line in sys.stdin:
        cmd=json.loads(line)
        if cmd['type']=='switch_session': session=cmd['sessionPath']
        if cmd['type']=='prompt':
            with open(log,'a') as f: f.write(json.dumps(cmd)+'\\n')
        data={'models': [], 'messages': [], 'disposition': 'handled', 'sessionFile':session}
        print(json.dumps({'type':'response','id':cmd['id'],'command':cmd['type'],'success':True,'data':data}),flush=True)
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let old = UserDefaults.standard.object(forKey: "piPath")
    UserDefaults.standard.set(script.path, forKey: "piPath")
    defer { UserDefaults.standard.set(old, forKey: "piPath") }
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    workspace.addProject(root)
    // Supply the same allowlisted metadata produced by discovery, without relying on
    // the machine's global ~/.pi session root in this hermetic test.
    let tab = try XCTUnwrap(workspace.tabs.first)
    tab.model.projectURL = root
    tab.model.sessions = [SessionItem(path: session.path, title: "old", modifiedAt: .now)]
    tab.model.composerText = "desktop draft"
    let selection = workspace.selectedTabID
    let commands = T3WorkspaceCommands()
    let request = RemoteBridgeRequest(
      id: "1", method: "session.send", text: " new question ",
      sessionPath: session.path, projectPath: root.path, commandId: "command",
      messageId: "mobile-message", images: [])
    let accepted = try await commands.send(request, workspace: workspace)
    XCTAssertTrue(accepted)
    var retry = request.withoutTransportID()
    retry = RemoteBridgeRequest(
      id: "retry", method: retry.method, text: retry.text,
      sessionPath: retry.sessionPath, projectPath: retry.projectPath, commandId: retry.commandId,
      messageId: retry.messageId, images: retry.images)
    let replay = try await commands.send(retry, workspace: workspace)
    XCTAssertTrue(replay)
    XCTAssertEqual(workspace.selectedTabID, selection)
    XCTAssertEqual(tab.model.composerText, "desktop draft")
    let remote = try XCTUnwrap(workspace.model(forSessionPath: session.path))
    XCTAssertEqual(remote.messages.last(where: { $0.kind == .user })?.id, "mobile-message")
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines.count, 1)
    let prompt = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
    XCTAssertEqual(prompt["message"] as? String, "new question")
  }

  func testInvalidTargetCannotStartProcessOrConsumeComposer() async throws {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let tab = try XCTUnwrap(workspace.tabs.first)
    tab.model.composerText = "keep"
    let count = workspace.tabs.count
    do {
      _ = try await T3WorkspaceCommands().send(
        RemoteBridgeRequest(
          id: "attack", method: "session.send", text: "hello",
          sessionPath: "/caller/path", projectPath: "/caller/project", commandId: "id",
          messageId: "msg"), workspace: workspace)
      XCTFail("Unknown targets must fail")
    } catch {}
    XCTAssertEqual(workspace.tabs.count, count)
    XCTAssertEqual(tab.model.composerText, "keep")
  }

  func testInlineImageValidationNeverFollowsPaths() throws {
    XCTAssertThrowsError(
      try T3ImageAttachments.materialize([
        T3RemoteImage(mimeType: "image/png", data: Data("/private/file".utf8).base64EncodedString())
      ]))
    let png =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6UAAAAABJRU5ErkJggg=="
    let result = try T3ImageAttachments.materialize([
      T3RemoteImage(mimeType: "image/png", data: png)
    ])
    defer { T3ImageAttachments.remove(result) }
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(try Data(contentsOf: result[0].url), Data(base64Encoded: png))
    XCTAssertThrowsError(
      try T3ImageAttachments.materialize([T3RemoteImage(mimeType: "image/jpeg", data: png)]))
  }
}

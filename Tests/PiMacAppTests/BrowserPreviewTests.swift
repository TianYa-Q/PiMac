import AppKit
import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct BrowserPreviewTests {
  private func tab(_ id: String, state: [String: Any]) -> [String: Any] {
    ["runtime": "server", "tabId": id, "navStatus": state]
  }

  @Test func keepsServerTabsAndTheirNavigationFailures() throws {
    let result: [String: Any] = [
      "sessions": [
        tab("one", state: ["_tag": "Success", "url": "https://example.com", "title": "示例"]),
        tab("two", state: ["_tag": "Idle"]),
        tab(
          "three",
          state: [
            "_tag": "LoadFailed", "url": "https://example.invalid", "title": "",
            "description": "DNS resolution failed",
          ]),
        ["runtime": "desktop"], [:],
      ]
    ]
    let tabs = try T3BrowserTab.read(result)
    #expect(tabs.map(\.id) == ["one", "two", "three"])
    #expect(tabs[0].title == "示例")
    #expect(tabs[1].url.isEmpty)
    #expect(tabs[2].title == "https://example.invalid")
    #expect(tabs[2].failure == "DNS resolution failed")
    #expect(try T3BrowserTab.read(["sessions": []]).isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func officialServerListAndInteractiveStreamUseAuthenticatedTransport() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/browser-preview-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "pimac-browser-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults)
    let client = T3DesktopClient(defaults: defaults)
    defer {
      client.stop()
      service.stop()
      workspace.disconnectAll()
    }
    // 所有 Provider 关闭，使用隔离 home；只验证官方列表、票据和画面路由，不接触账户。
    try startT3ProtocolFixture(
      service: service, workspace: workspace, stateDirectory: root, binary: nil,
      model: "test/model")
    client.start(service: service)
    try await client.waitUntilReady()
    let threadID = UUID().uuidString
    #expect(try await client.browserPreviewSessions(threadID: threadID).isEmpty)
    // 关闭已不存在的标签是幂等操作；同时覆盖原生新界面使用的 preview:operate 权限链路。
    try await client.updateBrowserPreviewTab(threadID: threadID, closing: "missing")
    #expect(try await client.browserPreviewSessions(threadID: threadID).isEmpty)
    let socket = try await client.browserPreviewSocket(threadID: threadID, tabID: "missing")
    defer { socket.cancel(with: .normalClosure, reason: nil) }
    do {
      _ = try await socket.receive()
      Issue.record("不存在的标签不得产生画面")
    } catch {
      // 4404 表示通过了认证并抵达浏览器流服务；不能把 401/403 当作“标签不存在”。
      #expect(socket.closeCode.rawValue == 4404)
    }
  }

  @Test func controlNotificationsGateInputWithoutOptimisticTakeover() throws {
    let agent = try T3BrowserEvent.read(
      #"{"type":"control","canOperate":true,"controller":"agent","generation":2,"dialog":null}"#)
    let model = BrowserPreviewModel()
    defer { model.stop() }
    model.receive(agent)
    #expect(!model.control.isControlling)
    #expect(T3BrowserInput.takeControl.isAllowed(by: model.control))
    #expect(!T3BrowserInput.text("不要提前发送").isAllowed(by: model.control))
    model.send(.takeControl)
    #expect(model.control.owner == .agent)
    model.receive(
      try T3BrowserEvent.read(
        #"{"type":"control","canOperate":true,"controller":"you","generation":3,"dialog":{"type":"prompt","message":"名字？","defaultValue":"测试"}}"#
      ))
    #expect(model.control.isControlling)
    #expect(model.control.dialog?.defaultValue == "测试")
    #expect(T3BrowserInput.text("你好").isAllowed(by: model.control))
    #expect(T3BrowserInput.releaseControl.isAllowed(by: model.control))
    model.receive(
      try T3BrowserEvent.read(
        #"{"type":"control","canOperate":false,"controller":"you","generation":4,"dialog":null}"#))
    #expect(!model.control.isControlling)
    #expect(!T3BrowserInput.takeControl.isAllowed(by: model.control))
    for text in [
      #"{"type":"control","canOperate":1,"controller":"you","generation":1}"#,
      #"{"type":"control","canOperate":true,"controller":"unknown","generation":1}"#,
      #"{"type":"viewport","width":true,"height":200}"#,
      #"{"type":"viewport","width":0,"height":200}"#,
    ] {
      #expect(throws: (any Error).self) { try T3BrowserEvent.read(text) }
    }
  }

  @Test func canvasMapsLetterboxedAndDownsampledFramesToCSSPixels() throws {
    let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
    let rect = BrowserPreviewGeometry.imageRect(
      image: CGSize(width: 800, height: 400), bounds: bounds)
    #expect(rect == CGRect(x: 0, y: 150, width: 600, height: 300))
    let viewport = CGSize(width: 1600, height: 800)
    #expect(
      BrowserPreviewGeometry.point(
        CGPoint(x: 300, y: 300), imageRect: rect, viewport: viewport, clamp: false)
        == CGPoint(x: 800, y: 400))
    #expect(
      BrowserPreviewGeometry.point(
        CGPoint(x: 300, y: 50), imageRect: rect, viewport: viewport, clamp: false) == nil)
    // 拖出画面仍须发送边界内的抬起，否则页面会一直以为鼠标按着。
    #expect(
      BrowserPreviewGeometry.point(
        CGPoint(x: 900, y: 800), imageRect: rect, viewport: viewport, clamp: true)
        == CGPoint(x: 1599, y: 799))
  }

  @Test func nativeTextInputCommitsIMEAndPastesWithoutTruncatingUnicode() {
    let view = BrowserPreviewInputView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    var messages: [[String: Any]] = []
    view.send = { messages.append($0.payload) }
    view.interactive = true
    view.setMarkedText(
      "拼音", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(messages.isEmpty)
    #expect(view.hasMarkedText())
    view.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!view.hasMarkedText())
    #expect(messages.first?["text"] as? String == "你好")
    let long = String(repeating: "你好👩🏽‍💻", count: 2000)
    let chunks = T3BrowserInput.textChunks(long)
    #expect(chunks.joined() == long)
    #expect(chunks.allSatisfy { $0.utf16.count <= 8000 })
    #expect(BrowserPreviewInputView.modifiers([.command, .shift]) == 12)
    view.interactive = false
    view.insertText("无控制权不能输入", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(messages.count == 1)
  }

  @Test func humanBrowserControlBlocksDevelopmentReloadUntilReleased() throws {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let app = try #require(workspace.tabs.first?.model)
    #expect(!workspace.restartBlockers.contains("浏览器正在由用户操作"))
    app.browserPreview.receive(
      .control(.init(canOperate: true, owner: .you, generation: 1, dialog: nil)))
    #expect(workspace.restartBlockers.contains("浏览器正在由用户操作"))
    // 只阻止宿主重载，不额外限制 Server 的模型或 Provider 切换能力。
    #expect(app.canRestartSafely)
    app.disconnect()
    #expect(!app.browserPreview.control.isControlling)
    #expect(!workspace.restartBlockers.contains("浏览器正在由用户操作"))
  }

  @Test func nativeCanvasReleasesHeldKeysWhenFocusMovesAway() throws {
    let view = BrowserPreviewInputView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    view.interactive = true
    var messages: [[String: Any]] = []
    view.send = { messages.append($0.payload) }
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123))
    view.keyDown(with: event)
    _ = view.resignFirstResponder()
    #expect(messages.map { $0["action"] as? String } == ["down", "up"])
    #expect(messages.allSatisfy { $0["key"] as? String == "ArrowLeft" })
    let enter = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    view.keyDown(with: enter)
    #expect(messages.last?["text"] as? String == "\r")
    _ = view.resignFirstResponder()
    #expect(messages.last?["action"] as? String == "up")
    #expect(messages.last?["text"] == nil)
  }

  @Test func backgroundTabsStayCollapsedAndHidingReleasesLocalOwnership() throws {
    let model = BrowserPreviewModel()
    defer { model.stop() }
    let hidden = T3BrowserTab(id: "a", title: "后台", url: "", failure: nil, revealID: nil)
    let shown = T3BrowserTab(id: "b", title: "预览", url: "", failure: nil, revealID: "show-1")
    model.apply([hidden])
    #expect(!model.visible)
    model.apply([hidden, shown])
    #expect(model.visible)
    #expect(model.selectedTab?.id == "b")
    model.setVisible(false)
    model.apply([hidden, shown])
    #expect(!model.visible)
    model.receive(.control(.init(canOperate: true, owner: .you, generation: 1, dialog: nil)))
    model.setVisible(false)
    #expect(!model.control.isControlling)
    let controller = BrowserPreviewWindowController(model: model)
    #expect(controller.window?.styleMask.contains(.resizable) == true)
    #expect(controller.window?.minSize == NSSize(width: 640, height: 480))
    controller.window?.contentView = nil
  }

  @Test func preservesBackgroundOnlyAndExplicitRevealRequests() throws {
    var background = tab("background", state: ["_tag": "Idle"])
    background["reveal"] = false
    var revealed = tab("revealed", state: ["_tag": "Idle"])
    revealed["reveal"] = true
    var requested = revealed
    requested["tabId"] = "requested"
    requested["revealRequest"] = ["id": "request-2", "force": true]
    let tabs = try T3BrowserTab.read(["sessions": [background, revealed, requested]])
    #expect(tabs.map(\.revealID) == [nil, "revealed", "request-2"])
  }

  @Test func corruptStateIsNotSilentlyPresentedAsNoBrowser() {
    let valid = tab("one", state: ["_tag": "Idle"])
    let invalid: [[String: Any]] = [
      [:], ["sessions": "invalid"], ["sessions": [["runtime": "unknown"]]],
      ["sessions": [["runtime": 1]]], ["sessions": [valid, valid]],
      ["sessions": [tab("", state: ["_tag": "Idle"])]],
      ["sessions": [tab("one", state: ["_tag": "NewState"])]],
      ["sessions": [tab("one", state: ["_tag": "Success", "url": "https://example.com"])]],
      [
        "sessions": [
          tab(
            "one",
            state: [
              "_tag": "LoadFailed", "url": "https://example.com", "title": "",
            ])
        ]
      ],
    ]
    for result in invalid {
      #expect(throws: T3DesktopClient.ClientError.self) { try T3BrowserTab.read(result) }
    }
  }
}

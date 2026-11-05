import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct DraftAccountSwitchTests {
  @Test func draftSwitchAvailabilityUsesConnectionRatherThanThreadExistence() {
    let client = T3DesktopClient()
    let app = AppModel(restoreLastProjectOnLaunch: false, initialComposerText: "保留草稿")
    app.attach(to: client)
    defer {
      app.disconnect()
      client.stop()
    }
    app.selectedModelId = "openai/gpt-5"
    #expect(!app.supportsAccountSwitch)
    client.didCompletePoll()
    #expect(app.threadID == nil)
    #expect(app.supportsAccountSwitch)
    #expect(app.canRestartSafely)
    app.isStreaming = true
    #expect(!app.canRestartSafely)
    app.isStreaming = false
    app.currentSessionPath = "t3:existing"
    #expect(app.supportsAccountSwitch)
    app.selectedModelId = "anthropic/claude"
    #expect(!app.supportsAccountSwitch)
    app.selectedModelId = "openai-codex/gpt-5"
    #expect(app.supportsAccountSwitch)
    #expect(app.composerText == "保留草稿")
  }

  @Test func draftShowsDefaultWithoutRebindingExistingSession() throws {
    let ui = ExtensionUIModel()
    let app = AppModel(restoreLastProjectOnLaunch: false)
    let client = T3DesktopClient()
    app.attach(to: client)
    defer {
      app.disconnect()
      client.stop()
    }
    client.didCompletePoll()
    app.selectedModelId = "openai/gpt-5"
    app.currentSessionPath = "t3:existing"
    let data = try JSONSerialization.data(
      withJSONObject: [
        "version": 2, "provider": "openai", "activeAccount": "X", "defaultAccount": "Y",
        "updatedAt": 1_900_000_000_000,
        "accounts": [["name": "X"], ["name": "Y"]],
      ] as [String: Any])
    ui.handle(
      [
        "method": "setStatus", "id": "accounts", "statusKey": "account-usage-gui",
        "statusText": String(decoding: data, as: UTF8.self),
      ], from: app)
    #expect(ui.usage(for: app).accounts.first(where: \.isActive)?.name == "X")
    app.currentSessionPath = ""
    #expect(ui.usage(for: app).accounts.first(where: \.isActive)?.name == "Y")
    app.currentSessionPath = "t3:existing"
    #expect(ui.usage(for: app).accounts.first(where: \.isActive)?.name == "X")
  }

  @Test func unconfirmedDraftSwitchPreservesInputAndDoesNotCreateThread() async throws {
    let client = T3DesktopClient()
    let app = AppModel(restoreLastProjectOnLaunch: false, initialComposerText: "保留草稿")
    let ui = ExtensionUIModel()
    app.attach(to: client)
    app.extensionUI = ui
    defer {
      app.disconnect()
      client.stop()
    }
    app.selectedModelId = "openai/gpt-5"
    client.didCompletePoll()
    let data = try JSONSerialization.data(
      withJSONObject: [
        "version": 2, "provider": "openai", "defaultAccount": "X",
        "accounts": [["name": "X"], ["name": "Y"]],
      ] as [String: Any])
    ui.handle(
      [
        "method": "setStatus", "id": "accounts", "statusKey": "account-usage-gui",
        "statusText": String(decoding: data, as: UTF8.self),
      ], from: app)
    app.switchCodexAccount(to: "Y")
    #expect(app.isBusy)
    // 未连接服务的真实客户端必须失败，不能把请求未执行显示为成功。
    for _ in 0..<100 where app.isBusy {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!app.isBusy)
    #expect(app.statusText.contains("账户切换未确认"))
    #expect(app.threadID == nil)
    #expect(app.messages.isEmpty)
    #expect(app.composerText == "保留草稿")
  }
}

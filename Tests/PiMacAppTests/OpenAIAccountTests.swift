import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct OpenAIAccountTests {
  private func model(_ provider: String, ui: ExtensionUIModel) -> AppModel {
    let app = AppModel(restoreLastProjectOnLaunch: false)
    app.allModels = [
      PiModel(
        provider: provider, modelId: "test", name: "test",
        api: provider == "openai" ? "openai-responses" : "openai-codex-responses")
    ]
    app.selectedModelId = provider + "/test"
    app.extensionUI = ui
    return app
  }

  private func status(provider: String, manages: Bool, percent: Double, timestamp: Double = 1000)
    throws -> PiRPCClient.JSON
  {
    var payload: PiRPCClient.JSON = [
      "version": 2, "provider": provider, "supportsAccountSwitch": true,
      "managesSelectedAuth": manages, "updatedAt": timestamp,
      "accounts": [
        ["name": "same", "primary": ["remainingPercent": percent, "windowSeconds": 18000]]
      ],
    ]
    if manages { payload["activeAccount"] = "same" }
    return [
      "id": UUID().uuidString, "method": "setStatus", "statusKey": "account-usage-gui",
      "statusText": String(
        decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self),
    ]
  }

  @Test func providerQuotaAndSameNamedAccountsNeverCrossContaminate() throws {
    let ui = ExtensionUIModel()
    let legacy = model("openai-codex", ui: ui)
    let modern = model("openai", ui: ui)
    ui.selectSource(legacy)
    ui.handle(try status(provider: "openai-codex", manages: true, percent: 2), from: legacy)
    ui.handle(try status(provider: "openai", manages: true, percent: 80), from: modern)
    #expect(ui.usage(for: legacy).accounts.first?.primary?.remainingPercent == 2)
    #expect(ui.usage(for: modern).accounts.first?.primary?.remainingPercent == 80)
    #expect(!modern.supportsAccountRotation)  // Adapter capability is not implemented.
    ui.selectSource(modern)
    #expect(ui.codexAccounts.first?.primary?.remainingPercent == 80)
    ui.handle(
      try status(provider: "openai-codex", manages: true, percent: 1, timestamp: 2000), from: legacy
    )
    #expect(ui.codexAccounts.first?.primary?.remainingPercent == 80)
  }

  @Test func changingProviderBeforeStatusArrivesUsesOnlyTheTargetQuotaSnapshot() throws {
    let ui = ExtensionUIModel()
    let legacy = model("openai-codex", ui: ui)
    let app = model("openai", ui: ui)
    app.allModels.append(legacy.allModels[0])
    ui.handle(try status(provider: "openai-codex", manages: true, percent: 2), from: legacy)
    ui.selectSource(app)
    ui.handle(try status(provider: "openai", manages: true, percent: 80), from: app)
    app.selectedModelId = "openai-codex/test"
    #expect(ui.usage(for: app).accounts.first?.primary?.remainingPercent == 2)
    #expect(ui.usage(for: app).accounts.first(where: \.isActive) == nil)
    #expect(!ui.managesSelectedAuth(for: app))
  }

  @Test func apiKeyIsNotMarkedActiveAndCannotAutoRotate() throws {
    let ui = ExtensionUIModel()
    let app = model("openai", ui: ui)
    ui.selectSource(app)
    ui.handle(try status(provider: "openai", manages: true, percent: 2), from: app)
    #expect(!app.supportsAccountRotation)
    ui.handle(
      try status(provider: "openai", manages: false, percent: 2, timestamp: 2000), from: app)
    #expect(!app.supportsAccountSwitch)  // Extension payloads cannot enable an unsupported capability.
    #expect(!app.supportsAccountRotation)
    #expect(ui.usage(for: app).accounts.first(where: \.isActive) == nil)
    #expect(ui.codexAccounts.first(where: \.isActive) == nil)
  }

  @Test func browserLoginCompletionDismissesOnlyItsOwnObsoletePrompts() {
    let ui = ExtensionUIModel()
    let first = model("openai", ui: ui)
    let second = model("openai", ui: ui)
    ui.handle(
      ["id": "login1", "method": "input", "title": "[account-usage login] Paste URL"], from: first)
    ui.handle(["id": "confirm", "method": "confirm", "title": "Allow tool?"], from: first)
    ui.handle(
      ["id": "login2", "method": "input", "title": "[account-usage login] Paste URL"], from: second)
    ui.handle(
      ["id": "done", "method": "setStatus", "statusKey": "account-usage-login"], from: first)
    #expect(ui.dialog?.id == "confirm")
    #expect(ui.hasPendingRequests(from: second))
    ui.answerDialog(cancelled: true)
    #expect(ui.dialog?.id == "login2")
  }

  @Test func oldExtensionCannotEnableOpenAIAccountSwitching() throws {
    let ui = ExtensionUIModel()
    let app = model("openai", ui: ui)
    #expect(!app.supportsAccountSwitch)
    var event = try status(provider: "openai-codex", manages: true, percent: 2)
    var payload = try #require(
      JSONSerialization.jsonObject(with: Data((event["statusText"] as! String).utf8))
        as? PiRPCClient.JSON)
    payload["version"] = 1
    payload.removeValue(forKey: "provider")
    event["statusText"] = String(
      decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    ui.handle(event, from: app)
    #expect(!app.supportsAccountSwitch && !app.supportsAccountRotation)
    #expect(ui.usage(for: app).accounts.isEmpty)
  }
}

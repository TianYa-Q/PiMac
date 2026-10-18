import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct AccountWorkspaceTests {
  private func snapshot(defaultName: String, hidden: Bool) -> [String: Any] {
    [
      "provider": "openai-codex", "monitorRunning": true, "records": [],
      "accounts": ["X", "Y"].map { name in
        [
          "name": name, "isDefault": name == defaultName, "isVisible": name != "Y" || !hidden,
          "primary": ["remainingPercent": 75], "secondary": NSNull(),
          "capturedAt": 1_800_000_000_000, "error": NSNull(),
        ] as [String: Any]
      },
    ]
  }

  private func settle(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("工作台操作未在测试时限内结束")
  }

  @Test func defaultAndVisibilityUpdateInPlaceWithoutResettingSelection() async throws {
    var current = snapshot(defaultName: "X", hidden: false)
    let model = AccountWorkspaceModel(
      provider: .legacyCodex, snapshot: nil,
      transport: { input in
        if input["operation"] as? String == "set-default" {
          current = snapshot(defaultName: "Y", hidden: false)
        } else if input["operation"] as? String == "visibility" {
          current = snapshot(defaultName: "Y", hidden: true)
        }
        return current
      }, openURL: { _ in })
    model.load()
    try await settle { !model.isWorking }
    #expect(model.page == .account("X"))
    model.page = .account("Y")
    model.perform(.setDefault("Y"))
    #expect(model.isWorking)
    try await settle { !model.isWorking }
    #expect(model.page == .account("Y"))
    #expect(model.selectedAccount?.isDefault == true)
    model.perform(.visibility("Y", false))
    try await settle { !model.isWorking }
    #expect(model.page == .account("Y"))
    #expect(model.selectedAccount?.isVisible == false)
    model.close()
  }

  @Test func failuresAndMalformedDataRetainLastTrustedSnapshot() async throws {
    let good = snapshot(defaultName: "X", hidden: false)
    var bad = false
    let model = AccountWorkspaceModel(
      provider: .legacyCodex, snapshot: nil,
      transport: { _ in bad ? ["accounts": []] : good }, openURL: { _ in })
    model.load()
    try await settle { !model.isWorking }
    bad = true
    model.page = .diagnostics
    model.perform(.health)
    try await settle { !model.isWorking }
    #expect(model.isError)
    #expect(model.snapshot?.accounts.count == 2)
    #expect(model.page == .diagnostics)
    model.close()
  }

  @Test func recordsRemainVisibleAndRefreshDoesNotNavigateAway() async throws {
    var data = snapshot(defaultName: "X", hidden: false)
    data["records"] = [
      ["timestamp": 1_800_000_000_000, "accountName": "X", "windowKind": "5h", "status": "failed"]
    ]
    let model = AccountWorkspaceModel(
      provider: .legacyCodex, snapshot: nil, transport: { _ in data }, openURL: { _ in })
    model.load()
    try await settle { !model.isWorking }
    model.page = .activity
    model.perform(.snapshot)
    try await settle { !model.isWorking }
    #expect(model.page == .activity)
    #expect(model.snapshot?.records.first?.status == "failed")
    model.close()
  }

  @Test func loginValidationAndCancellationKeepWorkspaceOpen() async throws {
    let good = snapshot(defaultName: "X", hidden: false)
    var cancelled = false
    var openedURL = false
    let model = AccountWorkspaceModel(
      provider: .legacyCodex, snapshot: nil,
      transport: { input in
        let operation = input["operation"] as? String
        if operation == "snapshot" { return good }
        if operation == "cancel" { cancelled = true }
        return [
          "flowID": "login-fixture", "busy": !cancelled,
          "outcome": cancelled ? "cancelled" : "working",
          "requests": [],
          "events": [
            ["serial": 1, "method": "account_auth_url", "url": "https://example.com/authorize"]
          ],
        ]
      }, openURL: { _ in openedURL = true })
    model.load()
    try await settle { !model.isWorking }
    model.startLogin(name: "X", replacing: false)
    #expect(model.isError)
    #expect(!model.isAuthorizing)
    model.startLogin(name: "bad name", replacing: false)
    #expect(!model.isAuthorizing)
    model.startLogin(name: "New", replacing: false)
    try await settle { openedURL }
    #expect(model.page == .add)
    model.cancelLogin()
    try await settle { !model.isAuthorizing && cancelled }
    #expect(model.snapshot?.accounts.count == 2)
    #expect(model.page == .add)
    #expect(!model.isError)
    model.close()
  }

  @Test func authorizationReplyCannotBeSubmittedTwiceWhilePolling() async throws {
    let data = snapshot(defaultName: "X", hidden: false)
    var replies = 0
    let model = AccountWorkspaceModel(
      provider: .legacyCodex, snapshot: nil,
      transport: { input in
        if input["operation"] as? String == "snapshot" { return data }
        if input["operation"] as? String == "respond" { replies += 1 }
        return [
          "flowID": "login-fixture", "busy": true, "outcome": "working", "events": [],
          "requests": [["id": "prompt", "method": "input", "title": "Paste callback"]],
        ]
      }, openURL: { _ in })
    model.load()
    try await settle { !model.isWorking }
    model.startLogin(name: "New", replacing: false)
    try await settle { model.authorizationRequest != nil }
    let request = try #require(model.authorizationRequest)
    model.respond(to: request, value: "callback", confirmed: nil)
    try await settle { !model.responding }
    model.respond(to: request, value: "callback", confirmed: nil)
    #expect(replies == 1)
    #expect(model.authorizationRequest == nil)
    model.cancelLogin()
    try await settle { !model.isAuthorizing }
    model.close()
  }
}

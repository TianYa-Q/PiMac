import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ExtensionUIModelTests {
  @Test
  func accountStatusFollowsSelectedSession() throws {
    let ui = ExtensionUIModel()
    let first = AppModel(restoreLastProjectOnLaunch: false)
    let second = AppModel(restoreLastProjectOnLaunch: false)

    ui.selectSource(first)
    ui.handle(
      try statusEvent(activeAccount: "X", updatedAt: 1_000, remainingPercent: 10),
      from: first
    )
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "X")

    // A background session may update the one shared quota snapshot, but cannot replace the
    // account selected by the foreground session.
    ui.handle(
      try statusEvent(activeAccount: "Y", updatedAt: 3_000, remainingPercent: 30),
      from: second
    )
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "X")
    #expect(ui.codexAccounts.first(where: { $0.name == "X" })?.primary?.remainingPercent == 30)

    ui.selectSource(second)
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "Y")
    #expect(ui.codexAccounts.first(where: { $0.name == "X" })?.primary?.remainingPercent == 30)

    // Even a newer update from another process must not change the selected account marker,
    // while its quota data remains globally authoritative.
    ui.handle(
      try statusEvent(activeAccount: "X", updatedAt: 4_000, remainingPercent: 40),
      from: first
    )
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "Y")
    #expect(ui.codexAccounts.first(where: { $0.name == "X" })?.primary?.remainingPercent == 40)

    ui.removeRequests(from: second)
    #expect(!ui.codexAccounts.isEmpty)
    #expect(ui.codexAccounts.allSatisfy { !$0.isActive })
    #expect(ui.codexAccounts.first(where: { $0.name == "X" })?.primary?.remainingPercent == 40)
  }

  private func statusEvent(
    activeAccount: String, updatedAt: Double, remainingPercent: Double
  ) throws -> PiRPCClient.JSON {
    let status: PiRPCClient.JSON = [
      "version": 1,
      "activeAccount": activeAccount,
      "defaultAccount": "X",
      "updatedAt": updatedAt,
      "accounts": [
        [
          "name": "X",
          "primary": ["remainingPercent": remainingPercent],
        ],
        ["name": "Y"],
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: status)
    return [
      "type": "extension_ui_request",
      "method": "setStatus",
      "id": UUID().uuidString,
      "statusKey": "account-usage-gui",
      "statusText": String(decoding: data, as: UTF8.self),
    ]
  }
}

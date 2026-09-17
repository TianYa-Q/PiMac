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
    ui.handle(try statusEvent(activeAccount: "X", updatedAt: 1_000), from: first)
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "X")

    // A background session keeps its own snapshot and cannot replace the selected session.
    ui.handle(try statusEvent(activeAccount: "Y", updatedAt: 3_000), from: second)
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "X")

    ui.selectSource(second)
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "Y")

    // Even a newer update from another process must not change the selected account marker.
    ui.handle(try statusEvent(activeAccount: "X", updatedAt: 4_000), from: first)
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "Y")

    ui.removeRequests(from: second)
    #expect(ui.codexAccounts.isEmpty)
  }

  private func statusEvent(activeAccount: String, updatedAt: Double) throws -> PiRPCClient.JSON {
    let status: PiRPCClient.JSON = [
      "version": 1,
      "activeAccount": activeAccount,
      "defaultAccount": "X",
      "updatedAt": updatedAt,
      "accounts": [
        ["name": "X"],
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

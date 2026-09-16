import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ExtensionUIModelTests {
  @Test
  func accountStatusIsGlobalAndSurvivesSessionSelection() throws {
    let ui = ExtensionUIModel()
    let first = AppModel(restoreLastProjectOnLaunch: false)
    let second = AppModel(restoreLastProjectOnLaunch: false)

    ui.handle(try statusEvent(activeAccount: "X", updatedAt: 1_000), from: first)
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "X")

    // Creating another task does not clear the application-wide snapshot.
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "X")

    // Any session can publish a newer global snapshot.
    ui.handle(try statusEvent(activeAccount: "Y", updatedAt: 3_000), from: second)
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "Y")

    // Late results from another process must not roll global quota state back.
    ui.handle(try statusEvent(activeAccount: "X", updatedAt: 2_000), from: first)
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "Y")

    ui.removeRequests(from: second)
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "Y")
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

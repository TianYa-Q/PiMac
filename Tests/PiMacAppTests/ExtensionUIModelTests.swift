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

    // Selecting a newly opened task must keep the old account visible until its process reports
    // the session selection, rather than briefly showing the empty/waiting state.
    ui.selectSource(second)
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "X")

    // Its initial extension payload establishes the session account without making the
    // application-wide quota card appear refreshed.
    ui.handle(
      try statusEvent(activeAccount: "Y", updatedAt: 3_000, remainingPercent: 30),
      from: second
    )
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "Y")
    #expect(ui.codexAccounts.first(where: { $0.name == "X" })?.primary?.remainingPercent == 10)
    #expect(ui.codexAccountsUpdatedAt == Date(timeIntervalSince1970: 1))

    // A later payload from that process is an actual periodic or explicit refresh and may
    // replace the shared quota snapshot.
    ui.handle(
      try statusEvent(activeAccount: "Y", updatedAt: 3_500, remainingPercent: 35),
      from: second
    )
    #expect(ui.codexAccounts.first(where: { $0.name == "X" })?.primary?.remainingPercent == 35)

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
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "Y")
    #expect(ui.codexAccounts.first(where: { $0.name == "X" })?.primary?.remainingPercent == 40)
  }

  @Test
  func backgroundStatusDoesNotEmptyAccountWhileSelectedProjectStarts() throws {
    let ui = ExtensionUIModel()
    let first = AppModel(restoreLastProjectOnLaunch: false)
    let starting = AppModel(restoreLastProjectOnLaunch: false)

    ui.selectSource(first)
    ui.handle(
      try statusEvent(activeAccount: "X", updatedAt: 1_000, remainingPercent: 10),
      from: first
    )
    ui.selectSource(starting)

    // The old project's process may publish again before the newly selected project has sent
    // its initial status. Shared quota updates must retain the last visible account meanwhile.
    ui.handle(
      try statusEvent(activeAccount: "X", updatedAt: 2_000, remainingPercent: 20),
      from: first
    )

    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "X")
    #expect(ui.codexAccounts.first(where: { $0.name == "X" })?.primary?.remainingPercent == 20)
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

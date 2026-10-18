import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ExtensionUIModelTests {
  @Test func hostAndSessionDialogPollingDoNotCancelEachOther() {
    let ui = ExtensionUIModel()
    let source = AppModel(restoreLastProjectOnLaunch: false)
    ui.handle(
      ["method": "select", "id": "pimac-account:one", "title": "宿主", "options": ["关闭"]],
      from: source)
    ui.handle(
      ["method": "input", "id": "pi-request", "title": "会话"], from: source)
    #expect(ui.pendingDialogCount == 2)
    ui.reconcileRequests(ids: ["pi-request"], from: source)
    #expect(ui.dialog?.id == "pimac-account:one")
    #expect(ui.dialogSourceLabel == "PiMac 账户管理")
    ui.reconcileRequests(ids: [], from: source, matchingPrefix: "pimac-account:")
    #expect(ui.dialog?.id == "pi-request")
    #expect(ui.pendingDialogCount == 1)
    ui.reconcileRequests(ids: [], from: source)
    #expect(ui.dialog == nil)
    #expect(ui.pendingDialogCount == 0)
  }

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
  func newSessionOnReusedProcessDoesNotRefreshSharedQuota() throws {
    let ui = ExtensionUIModel()
    let source = AppModel(restoreLastProjectOnLaunch: false)
    ui.selectSource(source)
    ui.handle(
      try statusEvent(activeAccount: "X", updatedAt: 1_000, remainingPercent: 10), from: source)

    ui.sessionWillChange(for: source)
    ui.handle(
      try statusEvent(activeAccount: "Y", updatedAt: 2_000, remainingPercent: 90), from: source)
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "Y")
    #expect(ui.codexAccounts.first(where: { $0.name == "X" })?.primary?.remainingPercent == 10)
    #expect(ui.codexAccountsUpdatedAt == Date(timeIntervalSince1970: 1))

    ui.handle(
      try statusEvent(activeAccount: "Y", updatedAt: 3_000, remainingPercent: 30), from: source)
    #expect(ui.codexAccounts.first(where: { $0.name == "X" })?.primary?.remainingPercent == 30)
    #expect(ui.codexAccountsUpdatedAt == Date(timeIntervalSince1970: 3))
  }

  @Test
  func remoteUsageUsesRemoteSelectionAndSharedQuota() throws {
    let ui = ExtensionUIModel()
    let desktop = AppModel(restoreLastProjectOnLaunch: false)
    let remote = AppModel(restoreLastProjectOnLaunch: false)
    ui.selectSource(desktop)
    ui.handle(
      try statusEvent(activeAccount: "X", updatedAt: 1_000, remainingPercent: 10), from: desktop)
    #expect(ui.usage(for: remote).accounts.first(where: \.isActive) == nil)
    ui.handle(
      try statusEvent(activeAccount: "Y", updatedAt: 2_000, remainingPercent: 90), from: remote)
    #expect(ui.usage(for: remote).accounts.first(where: \.isActive)?.name == "Y")
    #expect(AccountQuotaPresentation.accounts(ui.usage(for: remote).accounts).first?.name == "Y")
    #expect(AccountQuotaPresentation.accounts(ui.usage(for: desktop).accounts).first?.name == "X")
    #expect(
      ui.usage(for: remote).accounts.first(where: { $0.name == "X" })?.primary?.remainingPercent
        == 10)
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "X")
  }

  @Test
  func hostQuotaRefreshPreservesSwitchedSessionAndSelectionTimestamp() throws {
    let ui = ExtensionUIModel()
    let source = AppModel(restoreLastProjectOnLaunch: false)
    source.selectedModelId = "openai-codex/test"
    ui.selectSource(source)
    ui.handle(
      try statusEvent(activeAccount: "X", updatedAt: 1_000, remainingPercent: 10), from: source)
    ui.handle(
      try statusEvent(activeAccount: "Y", updatedAt: 2_000, remainingPercent: 20), from: source)

    ui.handle(try hostStatusEvent(updatedAt: 4_000, remainingPercent: 40), from: source)
    #expect(ui.codexAccounts.first?.name == "Y")
    #expect(ui.codexAccounts.first?.isActive == true)
    #expect(ui.supportsAccountSwitch(for: source))
    #expect(ui.managesSelectedAuth(for: source))
    #expect(ui.codexAccounts.first(where: { $0.name == "X" })?.primary?.remainingPercent == 40)

    // 较晚收到的真实会话状态不能被主机查询的时间戳挡住；共享额度仍保留较新值。
    ui.handle(
      try statusEvent(activeAccount: "X", updatedAt: 3_000, remainingPercent: 30), from: source)
    #expect(ui.codexAccounts.first?.name == "X")
    #expect(ui.codexAccounts.first?.isActive == true)
    #expect(ui.codexAccounts.first?.primary?.remainingPercent == 40)
  }

  @Test
  func hostQuotaRefreshDoesNotConsumeFirstSessionStatus() throws {
    let ui = ExtensionUIModel()
    let source = AppModel(restoreLastProjectOnLaunch: false)
    ui.selectSource(source)
    ui.handle(
      try statusEvent(activeAccount: "X", updatedAt: 1_000, remainingPercent: 10), from: source)
    ui.sessionWillChange(for: source)
    ui.handle(try hostStatusEvent(updatedAt: 2_000, remainingPercent: 40), from: source)
    ui.handle(
      try statusEvent(activeAccount: "Y", updatedAt: 3_000, remainingPercent: 90), from: source)
    #expect(ui.codexAccounts.first?.name == "Y")
    #expect(ui.codexAccounts.first(where: { $0.name == "X" })?.primary?.remainingPercent == 40)
    #expect(ui.codexAccountsUpdatedAt == Date(timeIntervalSince1970: 2))
  }

  @Test
  func hostThreadSelectionFollowsRotationWithoutReplacingQuota() throws {
    let ui = ExtensionUIModel()
    let source = AppModel(restoreLastProjectOnLaunch: false)
    source.selectedModelId = "openai-codex/test"
    ui.selectSource(source)
    ui.handle(
      try statusEvent(activeAccount: "X", updatedAt: 1_000, remainingPercent: 10), from: source)
    ui.handle(try hostStatusEvent(updatedAt: 9_000, remainingPercent: 40), from: source)

    func publishSelection(_ name: String, at time: Double) throws {
      let payload: PiRPCClient.JSON = [
        "version": 2, "provider": "openai-codex", "source": "host-query",
        "selectionOnly": true, "accounts": [], "updatedAt": 10_000,
        "sessionSelection": [
          "provider": "openai-codex", "activeAccount": name,
          "updatedAt": time, "supportsAccountSwitch": true, "managesSelectedAuth": true,
        ],
      ]
      ui.handle(
        [
          "method": "setStatus", "id": UUID().uuidString, "statusKey": "account-usage-gui",
          "statusText": String(
            decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self),
        ], from: source)
    }
    try publishSelection("Y", at: 2_000)
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "Y")
    #expect(ui.codexAccounts.count == 2)
    #expect(ui.codexAccounts.first(where: { $0.name == "X" })?.primary?.remainingPercent == 40)
    #expect(ui.codexAccountsUpdatedAt == Date(timeIntervalSince1970: 9))
    #expect(ui.supportsAccountSwitch(for: source))
    try publishSelection("X", at: 1_500)
    #expect(ui.codexAccounts.first(where: \.isActive)?.name == "Y")
  }

  private func hostStatusEvent(updatedAt: Double, remainingPercent: Double) throws
    -> PiRPCClient.JSON
  {
    let payload: PiRPCClient.JSON = [
      "version": 2, "provider": "openai-codex", "source": "host-query",
      "supportsAccountSwitch": false, "managesSelectedAuth": false,
      "updatedAt": updatedAt,
      "accounts": [
        ["name": "X", "primary": ["remainingPercent": remainingPercent]],
        ["name": "Y"],
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    return [
      "method": "setStatus", "id": UUID().uuidString, "statusKey": "account-usage-gui",
      "statusText": String(decoding: data, as: UTF8.self),
    ]
  }

  @Test
  func parsesStoredResetCredits() throws {
    let ui = ExtensionUIModel()
    let source = AppModel(restoreLastProjectOnLaunch: false)
    ui.selectSource(source)

    ui.handle(
      try statusEvent(
        activeAccount: "X",
        updatedAt: 1_000,
        remainingPercent: 10,
        resetCredits: [
          "availableCount": 2,
          "credits": [
            ["expiresAt": 1_800_000_000.0],
            ["expiresAt": 1_700_000_000.0],
          ],
        ]
      ),
      from: source
    )

    let credits = ui.codexAccounts.first?.resetCredits
    #expect(credits?.availableCount == 2)
    #expect(
      credits?.expirations.map(\.timeIntervalSince1970) == [
        1_700_000_000.0, 1_800_000_000.0,
      ])
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

  @Test func ordinaryStatusesAreIsolatedAndRemovedWithTheirSource() {
    let ui = ExtensionUIModel()
    let first = AppModel(restoreLastProjectOnLaunch: false)
    let second = AppModel(restoreLastProjectOnLaunch: false)
    func status(_ text: String, key: String = "progress") -> PiRPCClient.JSON {
      ["method": "setStatus", "id": UUID().uuidString, "statusKey": key, "statusText": text]
    }
    ui.selectSource(first)
    ui.handle(status("\u{001B}[31mFirst\u{001B}[0m"), from: first)
    ui.handle(status("Second"), from: second)
    #expect(ui.statuses["progress"] == "First")
    ui.selectSource(second)
    #expect(ui.statuses["progress"] == "Second")
    ui.handle(status(""), from: first)
    #expect(ui.statuses["progress"] == "Second")
    ui.handle(status("Quota", key: "account-usage"), from: second)
    ui.handle(status("", key: "account-usage"), from: second)
    #expect(ui.statuses["account-usage"] == "Quota")
    ui.removeRequests(from: second)
    #expect(ui.statuses.isEmpty)
    ui.selectSource(first)
    #expect(ui.statuses.isEmpty)
    ui.selectSource(second)
    #expect(ui.statuses.isEmpty)
  }

  private func statusEvent(
    activeAccount: String,
    updatedAt: Double,
    remainingPercent: Double,
    resetCredits: PiRPCClient.JSON? = nil
  ) throws -> PiRPCClient.JSON {
    var status: PiRPCClient.JSON = [
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
    if let resetCredits {
      var accounts = status["accounts"] as! [PiRPCClient.JSON]
      accounts[0]["resetCredits"] = resetCredits
      status["accounts"] = accounts
    }
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

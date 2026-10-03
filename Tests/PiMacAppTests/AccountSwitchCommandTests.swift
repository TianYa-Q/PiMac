import Testing

@testable import PiMacApp

@MainActor
struct AccountSwitchCommandTests {
  @Test func switchUsesTheExistingExtensionCommand() throws {
    #expect(try T3DesktopClient.sessionControlText(operation: "switch-account", accountName: "work-A_2.3") == "/accounts switch work-A_2.3")
    #expect(try T3DesktopClient.sessionControlText(operation: "compact") == "/compact")
    #expect(try T3DesktopClient.sessionControlText(operation: "manage-accounts") == "/accounts")
  }

  @Test func invalidOrSyntheticAccountsCannotBecomeCommands() {
    for name in ["", "Pi 已保存授权", "a b", "a\n/stop", "a\n", "a\r", "a/b", String(repeating: "a", count: 65)] {
      #expect(!T3DesktopClient.isSwitchableAccountName(name))
      #expect(throws: T3DesktopClient.ClientError.self) {
        try T3DesktopClient.sessionControlText(operation: "switch-account", accountName: name)
      }
    }
    #expect(throws: T3DesktopClient.ClientError.self) {
      try T3DesktopClient.sessionControlText(operation: "switch-account")
    }
    #expect(throws: T3DesktopClient.ClientError.self) {
      try T3DesktopClient.sessionControlText(operation: "unknown")
    }
  }

  @Test func disconnectedSessionCannotSwitchAccounts() {
    let app = AppModel(restoreLastProjectOnLaunch: false)
    app.selectedModelId = "openai/gpt-5"
    #expect(!app.supportsAccountSwitch)
    app.selectedModelId = "antigravity/gemini"
    #expect(!app.supportsAccountSwitch)
  }
}

import Testing

@testable import PiMacApp

@MainActor
struct AccountAccessTests {
  @Test func accountManagementRemainsAvailableDuringAgentWork() {
    let app = AppModel(restoreLastProjectOnLaunch: false)
    #expect(!app.canManageAccounts)
    app.connectionState = .connected
    #expect(app.canManageAccounts)
    app.isStreaming = true
    #expect(app.isBusy)
    #expect(app.canManageAccounts)
    app.isCompacting = true
    #expect(app.canManageAccounts)
    app.isLoadingConfiguration = true
    #expect(!app.canManageAccounts)
    app.isLoadingConfiguration = false
    app.connectionState = .disconnected
    #expect(!app.canManageAccounts)
  }

  @Test func loginLabelsDistinguishCredentialTypesWithoutChangingWireActions() throws {
    let options = ["切换账户", "刷新额度", "登录新账户", "删除账户", "额度显示设置", "自动启动记录", "关闭"]
    let legacy = try #require(
      AccountManagementPresentation(
        dialog: ExtensionDialog(
          id: "legacy", title: "Codex legacy 多账户管理", kind: .select(options: options))))
    let modern = try #require(
      AccountManagementPresentation(
        dialog: ExtensionDialog(
          id: "modern", title: "OpenAI ChatGPT 多账户管理", kind: .select(options: options))))
    #expect(legacy.credentialLabel == "Codex Legacy")
    #expect(legacy.loginTitle == "登录 Legacy 账户")
    #expect(modern.credentialLabel == "Codex 新版 · ChatGPT")
    #expect(modern.loginTitle == "登录新版账户")
  }
}

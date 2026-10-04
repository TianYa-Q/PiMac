import Testing

@testable import PiMacApp

struct AccountManagementDialogTests {
  private let options = ["切换账户", "刷新额度", "登录新账户", "删除账户", "额度显示设置", "自动启动记录", "关闭"]

  @Test func separatesAccountNamesAndStatus() throws {
    let dialog = ExtensionDialog(
      id: "test", title: "Codex legacy 多账户管理\n\nX\nY（当前会话、新会话默认）\nZ",
      kind: .select(options: options))
    let result = try #require(AccountManagementPresentation(dialog: dialog))
    #expect(result.provider == "Codex legacy")
    #expect(result.accounts.map(\.name) == ["X", "Y", "Z"])
    #expect(result.accounts[1].isCurrent)
    #expect(result.accounts[1].isDefault)
    #expect(!result.accounts[0].isCurrent)
  }

  @Test func handlesEmptyChatGPTAccounts() throws {
    let result = try #require(
      AccountManagementPresentation(
        dialog: ExtensionDialog(
          id: "test", title: "OpenAI ChatGPT 多账户管理\n\n尚未登录账户",
          kind: .select(options: options))))
    #expect(result.accounts.isEmpty)
    #expect(result.provider == "OpenAI ChatGPT")
  }

  @Test func preservesParenthesesInNamesAndSeparateStatuses() throws {
    let result = try #require(
      AccountManagementPresentation(
        dialog: ExtensionDialog(
          id: "test", title: "Codex legacy 多账户管理\n\nWork（team）\nA（当前会话）\nB（新会话默认）",
          kind: .select(options: options))))
    #expect(result.accounts[0].name == "Work（team）")
    #expect(result.accounts[1].isCurrent && !result.accounts[1].isDefault)
    #expect(!result.accounts[2].isCurrent && result.accounts[2].isDefault)
  }

  @Test func healthActionIsOptionalAndSearchPreservesIdentity() throws {
    let result = try #require(
      AccountManagementPresentation(
        dialog: ExtensionDialog(
          id: "test", title: "OpenAI ChatGPT 多账户管理\n\nWork\nPersonal\nWORK-backup（当前会话）",
          kind: .select(options: Array(options.dropLast()) + ["健康检查", "关闭"]))))
    #expect(result.supportsHealthCheck)
    #expect(result.filteredAccounts(query: " work ").map(\.name) == ["Work", "WORK-backup"])
    #expect(result.filteredAccounts(query: "backup").first?.id == 2)
    #expect(result.filteredAccounts(query: "missing").isEmpty)
    #expect(result.filteredAccounts(query: "  ").count == 3)
    let legacy = try #require(
      AccountManagementPresentation(
        dialog: ExtensionDialog(
          id: "old", title: "Codex legacy 多账户管理", kind: .select(options: options))))
    #expect(!legacy.supportsHealthCheck)
  }

  @Test func leavesOtherExtensionDialogsUnchanged() {
    #expect(
      AccountManagementPresentation(
        dialog: ExtensionDialog(
          id: "test", title: "其他菜单", kind: .select(options: options))) == nil)
    #expect(
      AccountManagementPresentation(
        dialog: ExtensionDialog(
          id: "test", title: "Codex legacy 多账户管理", kind: .select(options: ["关闭"]))) == nil)
    #expect(
      AccountManagementPresentation(
        dialog: ExtensionDialog(
          id: "test", title: "Codex legacy 多账户管理", kind: .confirm(message: "确定？"))) == nil)
  }
}

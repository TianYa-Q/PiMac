import Testing

@testable import PiMacApp

struct AccountVisibilityDialogTests {
  @Test func separatesVisibilityAndPreservesResponseValues() throws {
    let result = try #require(
      AccountVisibilityPresentation(
        dialog: ExtensionDialog(
          id: "test", title: "选择要显示或隐藏额度的账户",
          kind: .select(options: ["✓ X", "○ Work account", "✓ ✓ special"]))))
    #expect(result.accounts.map(\.name) == ["X", "Work account", "✓ special"])
    #expect(result.accounts.map(\.isVisible) == [true, false, true])
    #expect(result.accounts.map(\.option) == ["✓ X", "○ Work account", "✓ ✓ special"])
    #expect(result.accounts.map(\.id) == [0, 1, 2])
  }

  @Test func filtersByNameAndVisibilityWithoutChangingWireOptions() throws {
    let result = try #require(
      AccountVisibilityPresentation(
        dialog: ExtensionDialog(
          id: "test", title: "选择要显示或隐藏额度的账户",
          kind: .select(options: ["✓ Café", "○ WORK", "✓ Work two"]))))
    #expect(result.filteredAccounts(query: " cafe ").map(\.option) == ["✓ Café"])
    #expect(result.filteredAccounts(query: "work", filter: .hidden).map(\.option) == ["○ WORK"])
    #expect(result.filteredAccounts(query: "", filter: .visible).map(\.id) == [0, 2])
    #expect(result.filteredAccounts(query: "missing").isEmpty)
  }

  @Test func acceptsEmptyList() throws {
    let result = try #require(
      AccountVisibilityPresentation(
        dialog: ExtensionDialog(
          id: "test", title: "选择要显示或隐藏额度的账户", kind: .select(options: []))))
    #expect(result.accounts.isEmpty)
  }

  @Test func leavesOtherDialogsAndUnknownFormatsUnchanged() {
    #expect(
      AccountVisibilityPresentation(
        dialog: ExtensionDialog(
          id: "test", title: "其他菜单", kind: .select(options: ["✓ X"]))) == nil)
    #expect(
      AccountVisibilityPresentation(
        dialog: ExtensionDialog(
          id: "test", title: "选择要显示或隐藏额度的账户", kind: .select(options: ["X"]))) == nil)
    #expect(
      AccountVisibilityPresentation(
        dialog: ExtensionDialog(
          id: "test", title: "选择要显示或隐藏额度的账户", kind: .confirm(message: "确定？"))) == nil)
  }
}

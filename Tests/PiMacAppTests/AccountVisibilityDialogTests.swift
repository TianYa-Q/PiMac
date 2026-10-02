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

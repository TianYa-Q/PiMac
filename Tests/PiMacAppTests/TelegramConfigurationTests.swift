import XCTest

@testable import PiMacApp

final class TelegramConfigurationTests: XCTestCase {
  func testCredentialValidation() {
    XCTAssertTrue(TelegramControl.validCredentials(token: " 123:abc_DEF-9\n", userID: " 42 "))
    for token in ["", "abc:def", "123:", "123:abc def", "123:abc/def"] {
      XCTAssertFalse(TelegramControl.validCredentials(token: token, userID: "42"))
    }
    for id in ["", "0", "-42", "@name", "9223372036854775808"] {
      XCTAssertFalse(TelegramControl.validCredentials(token: "123:abc", userID: id))
    }
  }

  @MainActor
  func testConfigurationUsesInjectedDefaultsAndUnchangedSavePreservesDelivery() throws {
    let suite = "PiMac.TelegramConfiguration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let control = TelegramControl(defaults: defaults)
    try control.configure(token: " 123:secret ", userID: " 42 ", enabled: false)
    XCTAssertEqual(control.botToken, "123:secret")
    XCTAssertEqual(control.userID, "42")
    XCTAssertEqual(TelegramTokenStore.load(defaults: defaults), "123:secret")

    let notice = TelegramPendingNotice(id: UUID(), text: "等待发送", keyboard: nil)
    TelegramPendingNoticeStore.save([notice], defaults: defaults)
    let restored = TelegramControl(defaults: defaults)
    try restored.configure(token: "123:secret", userID: "42", enabled: false)
    XCTAssertEqual(TelegramPendingNoticeStore.load(defaults: defaults), [notice])
    try restored.configure(token: "456:new", userID: "42", enabled: false)
    XCTAssertTrue(TelegramPendingNoticeStore.load(defaults: defaults).isEmpty)
  }

  @MainActor
  func testConfigurationImpactWarnsOnlyForDestructiveChanges() throws {
    let suite = "PiMac.TelegramConfigurationImpact.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let control = TelegramControl(defaults: defaults)
    XCTAssertNil(control.configurationImpact(token: "123:secret", userID: "42", enabled: true))
    try control.configure(token: "123:secret", userID: "42", enabled: false)
    XCTAssertNil(control.configurationImpact(token: " 123:secret\n", userID: " 42 ", enabled: true))
    XCTAssertNil(control.configurationImpact(token: "123:secret", userID: "42", enabled: false))
    for (token, userID) in [("456:new", "42"), ("123:secret", "43"), ("", "")] {
      let impact = try XCTUnwrap(
        control.configurationImpact(token: token, userID: userID, enabled: false))
      XCTAssertTrue(impact.contains("未送达消息"))
      XCTAssertTrue(impact.contains("会话关联"))
    }
    // Model persisted enabled state without starting a network connection.
    defaults.set(true, forKey: "telegram.enabled")
    let disabled = try XCTUnwrap(
      control.configurationImpact(token: "123:secret", userID: "42", enabled: false))
    XCTAssertTrue(disabled.contains("等待任务"))
    XCTAssertTrue(disabled.contains("未送达消息会保留"))
    XCTAssertNil(control.configurationImpact(token: "123:secret", userID: "42", enabled: true))
  }

  @MainActor
  func testInvalidConfigurationDoesNotOverwriteCredentials() throws {
    let suite = "PiMac.TelegramInvalidConfiguration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let control = TelegramControl(defaults: defaults)
    try control.configure(token: "123:secret", userID: "42", enabled: false)
    XCTAssertThrowsError(try control.configure(token: "invalid", userID: "0", enabled: true))
    XCTAssertEqual(control.botToken, "123:secret")
    XCTAssertEqual(control.userID, "42")
    XCTAssertFalse(control.enabled)
  }
}

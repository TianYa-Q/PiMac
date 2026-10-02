import XCTest

@testable import PiMacApp

final class TelegramUsagePresentationTests: XCTestCase {
  func testLongLabelsAreNormalizedAndKeepModelSuffixes() {
    XCTAssertEqual(
      TelegramPresentation.compactLabel("  Fix\n the   bug ", limit: 20), "Fix the bug")
    XCTAssertEqual(TelegramPresentation.compactLabel("abcdef", limit: 5), "abcd…")
    XCTAssertEqual(TelegramPresentation.compactLabel("abcdef", limit: 0), "")
    let model = "provider/" + String(repeating: "model-", count: 12) + "-high"
    let compact = TelegramPresentation.compactLabel(model, limit: 45, preserveSuffix: true)
    XCTAssertEqual(compact.count, 45)
    XCTAssertTrue(compact.hasPrefix("provider/"))
    XCTAssertTrue(compact.hasSuffix("-high"))
    XCTAssertTrue(compact.contains("…"))
    XCTAssertEqual(TelegramPresentation.compactLabel("👩🏽‍💻👩🏽‍💻👩🏽‍💻", limit: 2), "👩🏽‍💻…")
  }

  func testPercentAndMetersHandleUnknownAndOutOfRangeValues() {
    XCTAssertEqual(TelegramPresentation.percent(72.5), "73%")
    XCTAssertEqual(TelegramPresentation.percent(-5), "0%")
    XCTAssertEqual(TelegramPresentation.percent(110), "100%")
    XCTAssertEqual(TelegramPresentation.percent(.nan), "待统计")
    XCTAssertEqual(TelegramPresentation.meter(0), "▱▱▱▱▱▱▱▱")
    XCTAssertEqual(TelegramPresentation.meter(50), "▰▰▰▰▱▱▱▱")
    XCTAssertEqual(TelegramPresentation.meter(100), "▰▰▰▰▰▰▰▰")
    XCTAssertNil(TelegramPresentation.meter(.infinity))
  }

  func testCacheAgeHandlesMissingFutureAndOldData() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertEqual(TelegramPresentation.cacheAge(updatedAt: nil, now: now), "缓存更新时间未知")
    XCTAssertEqual(
      TelegramPresentation.cacheAge(updatedAt: now.addingTimeInterval(10), now: now), "刚刚同步")
    XCTAssertEqual(
      TelegramPresentation.cacheAge(updatedAt: now.addingTimeInterval(-120), now: now), "2 分钟前同步")
    XCTAssertEqual(
      TelegramPresentation.cacheAge(updatedAt: now.addingTimeInterval(-3_600), now: now), "1 小时前同步")
    XCTAssertEqual(
      TelegramPresentation.cacheAge(updatedAt: now.addingTimeInterval(-86_400), now: now),
      "超过 1 天未同步")
  }

  @MainActor
  func testUsagePagesStayShortAndKeepGlobalAccountNumbers() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let accounts = (1...9).map { index in
      CodexAccountStatus(
        name: "account-\(index)", isActive: index == 1, isDefault: false, isHidden: false,
        primary: CodexUsageWindow(remainingPercent: 10, resetAt: nil, windowSeconds: 18_000),
        secondary: nil, resetCredits: nil, error: nil)
    }
    let gemini = GeminiUsageStatus(isConfigured: true, isActive: false, quotas: [], error: nil)
    let first = TelegramControl.usageMessage(
      accounts: accounts, gemini: gemini, updatedAt: now, now: now, page: 1)
    XCTAssertTrue(first.contains("1/3 页"))
    XCTAssertTrue(first.contains("4. ○ Codex account-4"))
    XCTAssertFalse(first.contains("Codex account-5"))
    XCTAssertTrue(first.contains("○ Gemini"))
    XCTAssertTrue(first.contains("⚠️ 额度偏低"))
    XCTAssertTrue(first.contains("仅本地缓存"))

    let last = TelegramControl.usageMessage(
      accounts: accounts, gemini: gemini, updatedAt: now.addingTimeInterval(-900),
      now: now, page: Int.max)
    XCTAssertTrue(last.contains("3/3 页"))
    XCTAssertTrue(last.contains("9. ○ Codex account-9"))
    XCTAssertFalse(last.contains("○ Codex account-8"))
    XCTAssertTrue(last.contains("当前 Codex：account-1"))
    XCTAssertTrue(last.contains("Gemini 额度在第 1 页"))
    XCTAssertTrue(last.contains("缓存较旧"))
  }

  @MainActor
  func testReadOnlyQuotaDoesNotImplyThreadBindingOrAccountSwitching() {
    let account = CodexAccountStatus(
      name: "X", isActive: false, isDefault: false, isHidden: false,
      primary: nil, secondary: nil, resetCredits: nil, error: nil)
    let message = TelegramControl.usageMessage(accounts: [account], gemini: nil, updatedAt: nil)
    XCTAssertTrue(message.contains("当前线程账户：未确认"))
    XCTAssertTrue(message.contains("不支持直接切换线程账户"))
    XCTAssertFalse(message.contains("待同步"))
    XCTAssertFalse(message.contains("空闲时可切换"))
    XCTAssertFalse(message.contains("默认"))
    let switchable = TelegramControl.usageMessage(
      accounts: [account], gemini: nil, updatedAt: nil, supportsAccountSwitch: true)
    XCTAssertTrue(switchable.contains("空闲时可切换"))
  }

  @MainActor
  func testStatusHighlightsConfirmationAndHighContext() {
    let status = TelegramControl.statusMessage(
      project: "demo", session: "任务", connection: .connected, busy: true,
      loading: false, detail: "", contextPercent: 92, queuedCount: 2,
      waitingForConfirmation: true)
    XCTAssertTrue(status.contains("⏸ 等待 Mac 确认"))
    XCTAssertTrue(status.contains("请在 Mac 处理扩展确认"))
    XCTAssertFalse(status.contains("⚡ 正在执行"))
    XCTAssertTrue(status.contains("⚠️ 占用较高"))
    XCTAssertTrue(status.contains("排队  2 条"))
    let low = TelegramControl.statusMessage(
      project: "demo", session: "任务", connection: .connected, busy: false,
      loading: false, detail: "", contextPercent: .nan)
    XCTAssertTrue(low.contains("上下文  待统计"))
    XCTAssertFalse(low.contains("⚠️ 占用较高"))
  }

  func testUsagePaginationCallbacksRequireAuthorizedPrivateChat() throws {
    func update(_ command: String, user: Int64 = 42, chat: String = "private") throws
      -> TelegramUpdate
    {
      let object: [String: Any] = [
        "update_id": 1,
        "callback_query": [
          "id": "callback", "from": ["id": user, "is_bot": false], "data": command,
          "message": ["message_id": 17, "chat": ["id": 42, "type": chat]],
        ],
      ]
      return try JSONDecoder().decode(
        TelegramUpdate.self, from: JSONSerialization.data(withJSONObject: object))
    }
    for command in ["/usage 2", "/accounts 3"] {
      XCTAssertEqual(try update(command).authorizedCallback(userID: 42)?.command, command)
      XCTAssertNil(try update(command, user: 43).authorizedCallback(userID: 42))
      XCTAssertNil(try update(command, chat: "group").authorizedCallback(userID: 42))
    }
    for command in ["/usage 0", "/usage -1", "/accounts abc", "/usage 2 extra"] {
      XCTAssertNil(try update(command).authorizedCallback(userID: 42))
    }
  }
}

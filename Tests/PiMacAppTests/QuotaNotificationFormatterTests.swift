import Testing
@testable import PiMacApp

struct QuotaNotificationFormatterTests {
  @Test func formatsAccountQuotaNotification() {
    let input = """
      当前 Y： 5h 100% ◴ 3h 36m · 7d 100% ◴ 6d 14h
      账户 X： 5h 100% ◴ 3h 36m · 7d 100% ◴ 5d
      """
    #expect(QuotaNotificationFormatter.format(input) == """
      **当前 Y**
      - 5 小时：剩余 100% · 3小时 36分钟后重置
      - 7 天：剩余 100% · 6天 14小时后重置

      **账户 X**
      - 5 小时：剩余 100% · 3小时 36分钟后重置
      - 7 天：剩余 100% · 5天后重置
      """)
  }

  @Test func preservesOtherNoticesAndUnknownQuotaFormats() {
    #expect(QuotaNotificationFormatter.format("账户已切换") == "账户已切换")
    #expect(QuotaNotificationFormatter.format("账户 X： 5h 50% · 7d 80%") == "**账户 X**\n- 5 小时：剩余 50%\n- 7 天：剩余 80%")
    let unknown = "账户 X： 5h 50% · 7d ???"
    #expect(QuotaNotificationFormatter.format(unknown) == unknown)
  }
}

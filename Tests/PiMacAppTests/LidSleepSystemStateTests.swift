import Testing

@testable import PiMacApp

struct LidSleepSystemStateTests {
  @Test func parsesOnlyKnownSystemFacts() {
    #expect(
      LidSleepSystemState.parse(
        settings: "System-wide power settings:\n SleepDisabled\t1\n",
        battery: "Now drawing from 'Battery Power'\n -InternalBattery 72%")
        == .available(onAC: false, sleepDisabled: true))
    #expect(
      LidSleepSystemState.parse(
        settings: " SleepDisabled 0\n", battery: "Now drawing from 'AC Power'\n")
        == .available(onAC: true, sleepDisabled: false))
    for invalid in ["", "SleepDisabled unknown", "SleepDisabled 1\nSleepDisabled 0"] {
      guard
        case .failed = LidSleepSystemState.parse(
          settings: invalid, battery: "Now drawing from 'AC Power'")
      else {
        Issue.record("损坏或缺失的开关不得解释为允许休眠")
        return
      }
    }
    guard case .failed = LidSleepSystemState.parse(settings: "SleepDisabled 0", battery: "") else {
      Issue.record("未知电源不得解释为电池供电")
      return
    }
  }

  @Test func reportsMismatchAndUnmanagedStateInsteadOfClaimingSuccess() {
    let inherited = LidSleepSystemState.available(onAC: false, sleepDisabled: true)
    #expect(
      inherited.managementDescription(requested: true, enabled: true, busy: false)
        .contains("状态异常"))
    let ac = LidSleepSystemState.available(onAC: true, sleepDisabled: true)
    #expect(
      ac.managementDescription(requested: true, enabled: false, busy: false)
        .contains("尚未接管"))
    #expect(
      ac.managementDescription(requested: true, enabled: true, busy: false)
        == "已接管 · 插电合盖不休眠")
    let battery = LidSleepSystemState.available(onAC: false, sleepDisabled: false)
    #expect(
      battery.managementDescription(requested: true, enabled: true, busy: false)
        == "已接管 · 电池供电允许休眠")
    #expect(
      LidSleepSystemState.failed("查询失败").managementDescription(
        requested: true, enabled: true, busy: false
      ).contains("不能保证"))
  }
}

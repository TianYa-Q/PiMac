import Testing

@testable import PiMacApp

struct LidSleepSettingsViewTests {
  @Test func batteryOverrideRequiresConfirmedSystemState() {
    #expect(
      LidSleepStatusKind(
        state: .available(onAC: false, sleepDisabled: true), requested: true,
        enabled: true, busy: false, batteryOverride: true) == .active)
    #expect(
      LidSleepStatusKind(
        state: .available(onAC: false, sleepDisabled: false), requested: true,
        enabled: true, busy: false, batteryOverride: true) == .attention)
    #expect(
      LidSleepSystemState.available(onAC: false, sleepDisabled: true)
        .managementDescription(
          requested: true, enabled: true, busy: false, batteryOverride: true)
        == "已接管 · 手动开启电池合盖运行")
  }

  @Test(arguments: [
    (LidSleepSystemState.checking, true, false, false, LidSleepStatusKind.checking),
    (.failed("查询失败"), true, true, false, .attention),
    (.available(onAC: true, sleepDisabled: true), true, false, true, .applying),
    (.available(onAC: true, sleepDisabled: true), true, true, false, .active),
    (.available(onAC: false, sleepDisabled: false), true, true, false, .battery),
    (.available(onAC: false, sleepDisabled: true), true, true, false, .attention),
    (.available(onAC: true, sleepDisabled: true), true, false, false, .attention),
    (.available(onAC: true, sleepDisabled: true), false, false, false, .attention),
    (.available(onAC: true, sleepDisabled: false), false, false, false, .off),
  ])
  func statusCardNeverConfusesIntentWithActiveManagement(
    testCase: (LidSleepSystemState, Bool, Bool, Bool, LidSleepStatusKind)
  ) {
    let (state, requested, enabled, busy, expected) = testCase
    #expect(
      LidSleepStatusKind(state: state, requested: requested, enabled: enabled, busy: busy)
        == expected)
  }
}

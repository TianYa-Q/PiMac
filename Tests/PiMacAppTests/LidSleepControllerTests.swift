import Foundation
import Testing

@testable import PiMacApp

struct LidSleepControllerTests {
  @Test func shellQuotingPreservesLiteralArguments() throws {
    let value = "a'b\n\"$HOME; echo unsafe"
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "printf %s \(LidSleepController.shellQuote(value))"]
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(data: data, encoding: .utf8) == value)
  }

  @Test func watchdogHasValidShellSyntaxAndSafetyGuards() throws {
    let script = LidSleepController.watchdogScript(directory: "/tmp/pimac-awake-test", pid: 123)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    // Syntax check only: never run privileged commands during tests.
    process.arguments = ["-n", "-c", script]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(script.contains("[ \"$original\" != 0 ]"))
    #expect(script.contains("Now drawing from 'AC Power'"))
    #expect(script.contains("desired=0"))
    #expect(script.contains("-le 10"))
    #expect(script.contains("trap '/usr/bin/pmset -a disablesleep 0;"))
    #expect(!script.contains("> \"$dir/state\""))
    #expect(script.contains("/bin/mkdir -m 755 \"$stateDir\" || exit 1"))
  }

  @Test(arguments: [
    ("1", "Yes", 0, "display:displaysleepnow\nac_closed"),
    ("1", "No", 0, "ac"),
    ("1", "Unknown", 0, "ac"),
    ("0", "Yes", 0, "battery"),
    ("1", "Yes", 1, "display:displaysleepnow\nac_display_error"),
  ])
  func displaySleepsOnlyWhenPoweredAndClosed(testCase: (String, String, Int, String)) throws {
    let (desired, lid, result, expected) = testCase
    // Mock both system commands: no real sleep or display changes in tests.
    let fragment = LidSleepController.displaySleepScript
      .replacingOccurrences(of: "/usr/sbin/ioreg", with: "mock_ioreg")
      .replacingOccurrences(of: "/usr/bin/pmset", with: "mock_pmset")
    let script = """
      mock_ioreg() { printf '%s\\n' '\"AppleClamshellState\" = \(lid)'; }
      mock_pmset() { printf 'display:%s\\n' "$*"; return \(result); }
      desired=\(desired)
      state=\(desired == "1" ? "ac" : "battery")
      \(fragment)
      printf '%s' "$state"
      """
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(data: data, encoding: .utf8) == expected)
  }

  @Test @MainActor func launchPreferenceDefaultsOffAndSessionCleanupPreservesIt() throws {
    let suite = "LidSleepControllerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = LidSleepController(defaults: defaults)
    #expect(!controller.enableOnLaunch)
    controller.restoreAtLaunch()  // No permission request when disabled.
    #expect(!controller.busy)
    defaults.set(true, forKey: LidSleepController.launchPreferenceKey)
    controller.stop()  // The same cleanup used on quit and errors.
    #expect(controller.enableOnLaunch)
    let reopened = LidSleepController(defaults: defaults)
    #expect(reopened.enableOnLaunch)
    reopened.setEnabled(false)  // An explicit user action clears the preference.
    #expect(!reopened.enableOnLaunch)
    #expect(!controller.enableOnLaunch)
  }

  @Test @MainActor func pendingLaunchRestoreIsCancelledByStop() async throws {
    let suite = "LidSleepControllerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: LidSleepController.launchPreferenceKey)
    let controller = LidSleepController(defaults: defaults)
    controller.restoreAtLaunch()
    controller.restoreAtLaunch()  // Must not schedule a second activation.
    controller.stop()
    await Task.yield()
    #expect(!controller.busy)
    #expect(!controller.enabled)
    #expect(controller.enableOnLaunch)
  }

  @Test @MainActor func userPermissionSurvivesFailureCleanupAndReopening() throws {
    let suite = "LidSleepControllerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: LidSleepController.requestedPreferenceKey)
    let controller = LidSleepController(defaults: defaults)
    #expect(controller.requested)
    #expect(!controller.enabled)
    controller.stop() // Failure/quit cleanup must not revoke user permission.
    #expect(controller.requested)
    let reopened = LidSleepController(defaults: defaults)
    #expect(reopened.requested)
    reopened.setEnabled(false)
    #expect(!reopened.requested)
    #expect(!LidSleepController(defaults: defaults).requested)
  }

  @Test @MainActor func existingLaunchPreferenceMigratesToUserPermission() throws {
    let suite = "LidSleepControllerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: LidSleepController.launchPreferenceKey)
    let controller = LidSleepController(defaults: defaults)
    #expect(controller.requested)
    controller.stop()
    #expect(controller.requested)
    controller.setEnabled(false)
    defaults.set(true, forKey: LidSleepController.launchPreferenceKey)
    #expect(!LidSleepController(defaults: defaults).requested)
  }

  @Test func resumeGraceIsBoundedAndOnlyStartsAfterSchedulingGap() {
    let start = Date(timeIntervalSince1970: 100)
    var window = LidSleepResumeWindow(now: start)
    let normal = window.tick(now: start.addingTimeInterval(1))
    #expect(!normal)
    let resumed = window.tick(now: start.addingTimeInterval(600))
    #expect(resumed)
    for second in 601...609 {
      let grace = window.tick(now: start.addingTimeInterval(Double(second)))
      #expect(grace)
    }
    let expired = window.tick(now: start.addingTimeInterval(610))
    #expect(!expired)
    let stillExpired = window.tick(now: start.addingTimeInterval(611))
    #expect(!stillExpired)
  }

  @Test(arguments: [
    ("100 102 104 106 108 110 112", "100", 0, "100:0\n102:0\n104:0\n106:0\n108:0\n110:0\n"),
    ("1000 1002 1004 1006 1008 1010", "100", 0,
      "1000:unknown\n1002:unknown\n1004:unknown\n1006:unknown\n1008:unknown\n"),
    ("1000 1002 1004 1006 1008 1010", "$fakeNow", 0,
      "1000:unknown\n1002:unknown\n1004:unknown\n1006:unknown\n1008:unknown\n1010:unknown\n"),
    ("1000 1002", "100", 1, ""),
  ])
  func watchdogLeaseSurvivesResumeButNotDeadOrRemovedLease(
    testCase: (String, String, Int, String)
  ) throws {
    let (times, stamp, result, expected) = testCase
    let fragment = LidSleepController.watchdogLeaseScript
      .replacingOccurrences(of: "/usr/bin/stat", with: "mock_stat")
      .replacingOccurrences(of: "/bin/date", with: "mock_date")
    let script = """
      mock_stat() { echo "\(stamp)"; return \(result); }
      mock_date() { echo "$fakeNow"; }
      dir=/unused
      lastTick=100
      resumeUntil=0
      current=0
      for fakeNow in \(times); do
        \(fragment)
        printf '%s:%s\\n' "$fakeNow" "$current"
      done
      """
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(data: data, encoding: .utf8) == expected)
  }

  @Test func appleScriptQuotingEscapesNestedSource() {
    #expect(LidSleepController.appleScriptQuote("a\\b\"c\nd") == "\"a\\\\b\\\"c\\nd\"")
  }
}

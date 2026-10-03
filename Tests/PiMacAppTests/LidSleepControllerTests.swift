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

  @Test func appleScriptQuotingEscapesNestedSource() {
    #expect(LidSleepController.appleScriptQuote("a\\b\"c\nd") == "\"a\\\\b\\\"c\\nd\"")
  }
}

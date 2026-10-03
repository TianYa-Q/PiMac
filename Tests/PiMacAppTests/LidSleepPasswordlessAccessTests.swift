import Foundation
import Testing

@testable import PiMacApp

struct LidSleepPasswordlessAccessTests {
  @Test(arguments: [
    "user\n", "user;id", "../root", "user name", "user:ALL", "", "root\nALL=(ALL) ALL",
  ])
  func unsafeUsernamesAreRejected(username: String) {
    #expect(LidSleepPasswordlessAccess.rulePath(for: username) == nil)
    #expect(LidSleepPasswordlessAccess.ruleContent(for: username) == nil)
    #expect(LidSleepPasswordlessAccess.installationScript(for: username) == nil)
    #expect(LidSleepPasswordlessAccess.removalScript(for: username, restoreSleep: true) == nil)
  }

  @Test func recognizesExistingAmphetaminePermissionWithoutInstallingAnotherRule() {
    let listing = """
      User tianya may run the following commands:
          (ALL) ALL
          (ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
      """
    #expect(LidSleepPasswordlessAccess.hasExistingPermission(in: listing))
    #expect(
      LidSleepPasswordlessAccess.hasExistingPermission(
        in:
          "(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0\n(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1"
      ))
  }

  @Test(arguments: [
    "/usr/bin/pmset -a disablesleep 0\n/usr/bin/pmset -a disablesleep 1",
    "(ALL) /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1",
    "(ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 1",
    "(other_user) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1",
    "(ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 0, PASSWD: /usr/bin/pmset -a disablesleep 1",
  ])
  func cachedCredentialsOrPartialPermissionsDoNotCountAsPasswordless(listing: String) {
    #expect(!LidSleepPasswordlessAccess.hasExistingPermission(in: listing))
  }

  @Test func ruleAllowsExactlyTwoFixedCommandsAndPassesVisudo() throws {
    let content = try #require(LidSleepPasswordlessAccess.ruleContent(for: "pimac_test"))
    let commands = try #require(content.components(separatedBy: "NOPASSWD: ").last)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(commands == "/usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1")
    #expect(!content.contains("*"))
    #expect(!content.contains("(ALL)"))
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try content.write(to: file, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
    // Parse a temporary file only. Never modify the system sudo configuration.
    process.arguments = ["-cf", file.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }

  @Test func setupScriptsHaveValidSyntaxAndDoNotOverwriteExistingFiles() throws {
    let install = try #require(LidSleepPasswordlessAccess.installationScript(for: "pimac_test"))
    let remove = try #require(
      LidSleepPasswordlessAccess.removalScript(for: "pimac_test", restoreSleep: false))
    #expect(install.contains("/usr/sbin/visudo -cf"))
    #expect(install.contains("/bin/chmod 440"))
    #expect(install.contains("[ ! -L \"$target\" ]"))
    #expect(install.contains("/bin/ln \"$tmp\" \"$target\""))
    #expect(!remove.contains("pmset"))  // Do not undo another tool's switch when not active.
    #expect(remove.contains("/private/etc/sudoers.d/pimac-lid-sleep-pimac_test"))
    for script in [install, remove] {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-n", "-c", script]
      try process.run()
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)
    }
  }

  @Test func passwordlessWatchdogUsesSudoOnlyForSleepSwitch() throws {
    let script = LidSleepController.watchdogScript(
      directory: "/tmp/pimac-test", pid: 123, passwordless: true)
    #expect(script.contains("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep \"$desired\""))
    #expect(script.contains("trap '/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0; :"))
    #expect(script.contains("stateDir='/tmp/pimac-test'"))
    #expect(!script.contains("/private/var/run"))
    #expect(!script.contains("sudo -n /bin/sh"))
    #expect(!script.contains("sudo -n /usr/bin/pmset displaysleepnow"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-n", "-c", script]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
}

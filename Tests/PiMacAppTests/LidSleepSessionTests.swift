import Foundation
import Testing

@testable import PiMacApp

struct LidSleepSessionTests {
  @Test func observationSeparatesHealthyDelayedDeadAndCorruptStates() throws {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/lid-sleep-observation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date.now
    #expect(LidSleepSessionObservation.read(directory: directory, now: now) == .lost)
    try "\(ProcessInfo.processInfo.processIdentifier)".write(
      to: directory.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
    #expect(LidSleepSessionObservation.read(directory: directory, now: now) == .delayed)
    let state = directory.appendingPathComponent("state")
    try "ac".write(to: state, atomically: true, encoding: .utf8)
    #expect(LidSleepSessionObservation.read(directory: directory, now: now) == .running(.ac))
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-30)], ofItemAtPath: state.path)
    #expect(LidSleepSessionObservation.read(directory: directory, now: now) == .delayed)
    try "".write(to: state, atomically: true, encoding: .utf8)
    guard case .invalid = LidSleepSessionObservation.read(directory: directory, now: now) else {
      Issue.record("空状态不应显示为电池模式")
      return
    }
    let exit = directory.appendingPathComponent("exit")
    try "power_failed:ok".write(to: exit, atomically: true, encoding: .utf8)
    #expect(
      LidSleepSessionObservation.read(directory: directory, now: now)
        == .ended(reason: .powerFailed, restored: true))
    try "bogus:ok".write(to: exit, atomically: true, encoding: .utf8)
    guard case .invalid = LidSleepSessionObservation.read(directory: directory, now: now) else {
      Issue.record("退出原因必须校验")
      return
    }
  }

  @Test func deadProcessCannotLookHealthyAndInvalidPIDIsNotAnEmptySession() throws {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/lid-sleep-dead-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try child.run()
    child.waitUntilExit()
    let pid = directory.appendingPathComponent("pid")
    try "\(child.processIdentifier)".write(to: pid, atomically: true, encoding: .utf8)
    try "ac".write(
      to: directory.appendingPathComponent("state"), atomically: true, encoding: .utf8)
    #expect(LidSleepSessionObservation.read(directory: directory, now: .now) == .lost)
    for invalidPID in ["", "0", "-1", "not-a-pid"] {
      try invalidPID.write(to: pid, atomically: true, encoding: .utf8)
      guard case .invalid = LidSleepSessionObservation.read(directory: directory, now: .now) else {
        Issue.record("损坏的 PID 不应触发自动恢复：\(invalidPID)")
        return
      }
    }
  }

  @Test(arguments: [
    ("normal", "set:1\nset:0\n", "app_exited:ok", 0),
    ("battery", "set:1\nset:0\nset:0\n", "app_exited:ok", 0),
    ("folderRemoved", "set:1\nset:0\n", "", 0),
    ("externalReset", "set:1\nset:1\nset:0\n", "app_exited:ok", 0),
    ("leaseRemoved", "set:1\nset:0\n", "lease_removed:ok", 0),
    ("pidReused", "set:1\nset:0\n", "app_exited:ok", 0),
    ("powerFailed", "set:1\nset:0\n", "power_failed:ok", 1),
    ("restoreFailed", "set:1\nset:0\n", "app_exited:failed", 0),
    ("queryFailed", "", "power_query_failed:unowned", 1),
    ("queryCommandFailed", "", "power_query_failed:unowned", 1),
    ("runtimeQueryFailed", "set:1\nset:0\n", "power_query_failed:ok", 1),
    ("powerSourceFailed", "set:0\n", "power_query_failed:ok", 1),
    ("conflict", "", "conflict:unowned", 1),
  ])
  func watchdogExecutesLifecycleWithoutRealPowerChanges(
    testCase: (String, String, String, Int32)
  ) throws {
    let (scenario, expectedCommands, expectedExit, expectedCode) = testCase
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/lid-sleep-watchdog-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = directory.appendingPathComponent("session")
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
    try Data().write(to: session.appendingPathComponent("lease"))
    let commands = directory.appendingPathComponent("commands")
    try Data().write(to: commands)
    // 执行完整生成脚本，只替换系统边界；任何场景都不调用真实 pmset/sudo 或休眠。
    let watchdog = LidSleepController.watchdogScript(
      directory: session.path, pid: 123, passwordless: true
    )
    .replacingOccurrences(of: "/usr/bin/sudo -n /usr/bin/pmset", with: "mock_pmset")
    .replacingOccurrences(of: "/usr/bin/pmset", with: "mock_pmset")
    .replacingOccurrences(of: "/usr/sbin/ioreg", with: "mock_ioreg")
    .replacingOccurrences(of: "/bin/ps", with: "mock_ps")
    .replacingOccurrences(of: "/bin/kill", with: "mock_kill")
    .replacingOccurrences(of: "/bin/sleep", with: "mock_sleep")
    let script = """
      scenario=\(scenario)
      testCommands=\(LidSleepController.shellQuote(commands.path))
      loops=0
      systemPower=0
      [ "$scenario" != conflict ] || systemPower=1
      [ "$scenario" != queryFailed ] || systemPower=bad
      mock_pmset() {
        if [ "$1" = -g ]; then
          if [ "$2" = batt ]; then
            [ "$scenario" != powerSourceFailed ] || return 1
            if [ "$scenario" = battery ] && [ "$loops" -ge 2 ]; then
              echo "Now drawing from 'Battery Power'"
            else
              echo "Now drawing from 'AC Power'"
            fi
          else
            echo "SleepDisabled $systemPower"
            [ "$scenario" != queryCommandFailed ] || return 1
          fi
        else
          printf 'set:%s\\n' "$3" >> "$testCommands"
          [ "$scenario:$3" != powerFailed:1 ] || return 1
          [ "$scenario:$3" != restoreFailed:0 ] || return 1
          systemPower=$3
        fi
      }
      mock_ioreg() { echo '\"AppleClamshellState\" = No'; }
      mock_ps() {
        if [ "$scenario" = pidReused ] && [ "$loops" -ge 2 ]; then
          echo newIdentity
        else
          echo originalIdentity
        fi
      }
      mock_kill() { loops=$((loops + 1)); [ "$loops" -le 3 ]; }
      mock_sleep() {
        if [ "$loops" = 1 ]; then
          [ "$scenario" != externalReset ] || systemPower=0
          [ "$scenario" != runtimeQueryFailed ] || systemPower=bad
          if [ "$scenario" = leaseRemoved ]; then
            /bin/mv "$dir/lease" "$dir/released"
          fi
          if [ "$scenario" = folderRemoved ]; then
            /bin/mv "$dir" "$dir-released"
          fi
        fi
        return 0
      }
      \(watchdog)
      """
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == expectedCode)
    #expect(data.isEmpty)
    #expect(try String(contentsOf: commands, encoding: .utf8) == expectedCommands)
    if scenario == "folderRemoved" { return }
    let exit = try String(contentsOf: session.appendingPathComponent("exit"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(exit == expectedExit)
    if scenario == "normal" {
      // 不存在 heartbeat，仍能连续运行；主线程无需每秒向 helper 证明自己活着。
      #expect(
        !FileManager.default.fileExists(atPath: session.appendingPathComponent("heartbeat").path))
      let state = try String(contentsOf: session.appendingPathComponent("state"), encoding: .utf8)
      #expect(state == "ac\n")
    }
  }
}

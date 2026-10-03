import Foundation
import SwiftUI

/// A session-only watchdog, optionally using two narrowly scoped sudo permissions.
@MainActor
final class LidSleepController: ObservableObject {
  static let shared = LidSleepController()
  @Published private(set) var enabled = false
  @Published private(set) var busy = false
  @Published private(set) var status = "未启用" {
    didSet { if status != oldValue { LidSleepDiagnostics.record(status) } }
  }
  @Published private(set) var passwordlessConfigured = false
  @Published private(set) var passwordlessAvailable = false
  private var sessionPasswordless = false
  private var sessionGeneration = UUID()
  private var directory: URL?
  private var timer: Timer?
  private let defaults: UserDefaults
  private var launchRestoreTask: Task<Void, Never>?
  private var didRestoreAtLaunch = false
  static let launchPreferenceKey = "PiMac.lidSleep.enableOnLaunch"

  var enableOnLaunch: Bool { defaults.bool(forKey: Self.launchPreferenceKey) }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    refreshPasswordlessAccess()
    Task { [weak self] in
      let available = await Task.detached {
        LidSleepPasswordlessAccess.existingPermissionAvailable()
      }.value
      self?.passwordlessAvailable = available
    }
  }

  private func refreshPasswordlessAccess() {
    passwordlessConfigured =
      LidSleepPasswordlessAccess.rulePath(for: NSUserName())
      .map { FileManager.default.fileExists(atPath: $0) } ?? false
  }

  func configurePasswordlessAccess(install: Bool) {
    guard !busy, !install || !enabled else { return }
    let needsRestore = enabled
    if !install {
      defaults.set(false, forKey: Self.launchPreferenceKey)
      stop()
    }
    let script =
      install
      ? LidSleepPasswordlessAccess.installationScript(for: NSUserName())
      : LidSleepPasswordlessAccess.removalScript(for: NSUserName(), restoreSleep: needsRestore)
    guard let script else {
      status = "当前账户名称不适用于免密码规则，未修改系统。"
      return
    }
    busy = true
    status = install ? "等待一次性管理员授权…" : "正在移除免密码权限…"
    let source = "do shell script \(Self.appleScriptQuote(script)) with administrator privileges"
    Task {
      if !install { try? await Task.sleep(for: .seconds(3)) }
      let error = await Task.detached { Self.authorize(source) }.value
      refreshPasswordlessAccess()
      busy = false
      if let error {
        status = "权限配置失败：\(error)"
      } else if install {
        setEnabled(true)
      } else {
        status = "已移除免密码权限，自动开启已关闭"
      }
    }
  }

  func restoreAtLaunch() {
    guard !didRestoreAtLaunch else { return }
    didRestoreAtLaunch = true
    guard enableOnLaunch else { return }
    // Let the previous app's watchdog restore its global switch on quick restarts.
    launchRestoreTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      guard let self, self.enableOnLaunch, !self.enabled, !self.busy else { return }
      self.setEnabled(true)
    }
  }

  func setEnabled(_ value: Bool) {
    guard !busy else { return }
    if !value {
      defaults.set(false, forKey: Self.launchPreferenceKey)
      stop()
      return
    }
    guard !enabled else { return }
    busy = true
    status = "正在检查免密码权限…"
    let generation = UUID()
    sessionGeneration = generation
    Task {
      let available = await Task.detached {
        LidSleepPasswordlessAccess.existingPermissionAvailable()
      }.value
      guard sessionGeneration == generation else {
        busy = false
        return
      }
      passwordlessAvailable = available
      refreshPasswordlessAccess()
      startSession(passwordless: available || passwordlessConfigured)
    }
  }

  private func startSession(passwordless: Bool) {
    sessionPasswordless = passwordless
    status = passwordless ? "正在免密码开启…" : "等待管理员授权…"
    LidSleepDiagnostics.record(passwordless ? "使用免密码命令权限" : "使用临时管理员授权")
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("pimac-awake-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      try Data().write(to: folder.appendingPathComponent("heartbeat"))
    } catch {
      busy = false
      status = "无法创建守护会话：\(error.localizedDescription)"
      return
    }
    directory = folder
    startHeartbeat()
    let script = Self.watchdogScript(
      directory: folder.path,
      pid: ProcessInfo.processInfo.processIdentifier, passwordless: passwordless)
    let command = "/bin/sh -c \(Self.shellQuote(script)) </dev/null >/dev/null 2>&1 & echo $!"
    let appleScript =
      "do shell script \(Self.appleScriptQuote(command)) with administrator privileges"
    Task {
      let result = await Task.detached { () -> String? in
        if passwordless {
          // Check permission without changing power settings or prompting. A broken
          // installation must fail visibly, never silently fall back to a prompt.
          for value in ["0", "1"] {
            if let error = Self.run(
              executable: "/usr/bin/sudo",
              arguments: [
                "-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", value,
              ])
            {
              return error
            }
          }
          return Self.run(executable: "/bin/sh", arguments: ["-c", command])
        }
        return Self.authorize(appleScript)
      }.value
      if let error = result {
        stop()
        status = "未启用：\(error)"
      } else {
        // Wait for the watchdog's initial ownership check, not just the launch command.
        for _ in 0..<30 {
          if let state = readState() {
            if state == "conflict" || state == "error" {
              stop()
              status =
                state == "conflict"
                ? "系统已由其他工具禁用休眠，请先恢复后再启用。"
                : "系统拒绝修改休眠设置，未启用。"
            } else {
              enabled = true
              // Only remember a successful activation; cancellation/failure must
              // not opt a first-time user into future authorization prompts.
              defaults.set(true, forKey: Self.launchPreferenceKey)
              updateStatus(state)
            }
            break
          }
          try? await Task.sleep(for: .milliseconds(100))
        }
        if !enabled && directory != nil {
          stop()
          status = "守护进程未就绪，已取消。"
        }
      }
      busy = false
    }
  }

  func stop() {
    // Session cleanup (including quit/error) must preserve the launch preference.
    sessionGeneration = UUID()
    launchRestoreTask?.cancel()
    launchRestoreTask = nil
    timer?.invalidate()
    timer = nil
    if let directory {
      // Removing the lease makes the watchdog restore sleep without another prompt.
      try? FileManager.default.removeItem(at: directory)
    }
    directory = nil
    enabled = false
    status = "已关闭，守护进程将在数秒内恢复休眠"
  }

  private func startHeartbeat() {
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, let directory = self.directory else { return }
        do {
          try Data().write(to: directory.appendingPathComponent("heartbeat"), options: .atomic)
        } catch {
          self.stop()
          self.status = "守护会话失效，正在恢复休眠"
          return
        }
        if self.enabled {
          guard let state = self.readState() else {
            self.stop()
            self.status = "守护进程失联，已停止会话；若系统仍无法休眠，请运行 sudo pmset -a disablesleep 0"
            return
          }
          if state == "error" {
            self.stop()
            self.status = "修改系统设置失败，正在恢复休眠"
          } else {
            self.updateStatus(state)
          }
        }
      }
    }
  }

  private func readState() -> String? {
    guard let directory else { return nil }
    let stateDirectory =
      sessionPasswordless
      ? directory
      : URL(fileURLWithPath: "/private/var/run")
        .appendingPathComponent(directory.lastPathComponent)
    let stateURL = stateDirectory.appendingPathComponent("state")
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: stateURL.path),
      let modified = attributes[.modificationDate] as? Date,
      Date.now.timeIntervalSince(modified) < 6
    else { return nil }
    return try? String(contentsOf: stateURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func updateStatus(_ state: String) {
    switch state {
    case "ac": status = "已插电：合盖保持运行，合盖时请求熄屏"
    case "ac_closed": status = "已插电、已合盖：已请求屏幕休眠，电脑继续运行"
    case "ac_display_error": status = "合盖保持运行，但熄屏请求失败"
    default: status = "未插电：使用正常休眠策略"
    }
  }

  nonisolated static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  nonisolated static func appleScriptQuote(_ value: String) -> String {
    "\""
      + value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n") + "\""
  }

  nonisolated private static func authorize(_ source: String) -> String? {
    run(executable: "/usr/bin/osascript", arguments: ["-e", source])
  }

  nonisolated private static func run(executable: String, arguments: [String]) -> String? {
    let process = Process()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    do {
      try process.run()
      let data = errors.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus != 0 else { return nil }
      let message = String(data: data, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      let error = message.flatMap { $0.isEmpty ? nil : $0 } ?? "命令失败、授权失败或已取消"
      LidSleepDiagnostics.record("\(executable) 退出码 \(process.terminationStatus)：\(error)")
      return error
    } catch {
      LidSleepDiagnostics.record("无法启动 \(executable)：\(error.localizedDescription)")
      return error.localizedDescription
    }
  }

  /// Display sleep is independent of system sleep. Repeat while closed so input or
  /// notifications cannot leave the display awake indefinitely. Unknown lid state
  /// must not blank an open laptop. This command sleeps ALL connected displays.
  nonisolated static let displaySleepScript = """
    if [ "$desired" = 1 ]; then
      lid=$(/usr/sbin/ioreg -r -k AppleClamshellState -d 1 | /usr/bin/awk '
        $1 == "\\"AppleClamshellState\\"" && $2 == "=" {print $3; exit}')
      if [ "$lid" = Yes ]; then
        if /usr/bin/pmset displaysleepnow; then
          state=ac_closed
        else
          state=ac_display_error
        fi
      fi
    fi
    """

  nonisolated static func watchdogScript(directory: String, pid: Int32, passwordless: Bool = false)
    -> String
  {
    // The passwordless watchdog is NOT root: only the exact pmset commands use sudo.
    // Legacy authorized mode passes code inline, never reads a user-writable script.
    let stateDirectory =
      passwordless
      ? directory
      : "/private/var/run/" + URL(fileURLWithPath: directory).lastPathComponent
    let powerCommand = passwordless ? "/usr/bin/sudo -n /usr/bin/pmset" : "/usr/bin/pmset"
    let cleanup = passwordless ? ":" : "/bin/rm -rf \"$stateDir\""
    return """
      dir=\(shellQuote(directory))
      stateDir=\(shellQuote(stateDirectory))
      umask 022
      # Root mode must never write into the user's lease directory.
      \(passwordless ? ":" : "/bin/mkdir -m 755 \"$stateDir\" || exit 1")
      trap '\(cleanup)' EXIT
      original=$(/usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" {print $2; exit}')
      if [ "$original" != 0 ]; then
        echo conflict > "$stateDir/state"
        /bin/sleep 3
        exit 1
      fi
      trap '\(powerCommand) -a disablesleep 0; \(cleanup)' EXIT
      trap 'exit' HUP INT TERM
      current=0
      while /bin/kill -0 \(pid) 2>/dev/null; do
        stamp=$(/usr/bin/stat -f %m "$dir/heartbeat" 2>/dev/null) || break
        now=$(/bin/date +%s)
        [ "$((now - stamp))" -le 10 ] || break
        desired=0
        state=battery
        if /usr/bin/pmset -g batt | /usr/bin/grep -q "Now drawing from 'AC Power'"; then
          desired=1
          state=ac
        fi
        if [ "$desired" != "$current" ]; then
          if ! \(powerCommand) -a disablesleep "$desired"; then
            echo error > "$stateDir/state"
            /bin/sleep 3
            exit 1
          fi
          current=$desired
        fi
        \(displaySleepScript)
        echo "$state" > "$stateDir/state" || break
        /bin/sleep 2
      done
      """
  }
}

struct LidSleepSettingsView: View {
  @ObservedObject private var controller = LidSleepController.shared
  @State private var confirming = false
  @State private var confirmingAccess = false
  @State private var installingAccess = true
  @AppStorage(LidSleepController.launchPreferenceKey) private var enableOnLaunch = false

  var body: some View {
    GroupBox("插电合盖运行") {
      VStack(alignment: .leading, spacing: 10) {
        Toggle(
          "合盖不休眠",
          isOn: Binding(
            get: { controller.enabled },
            set: { value in
              if value { confirming = true } else { controller.setEnabled(false) }
            })
        )
        .disabled(controller.busy)
        Toggle("启动时开启", isOn: $enableOnLaunch)
          .disabled(controller.busy)
        HStack {
          Text(
            controller.passwordlessConfigured
              ? "免密码已配置"
              : (controller.passwordlessAvailable ? "已有免密码权限" : "未配置免密码")
          )
          .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button(controller.passwordlessConfigured ? "移除权限" : "配置免密码") {
            installingAccess = !controller.passwordlessConfigured
            confirmingAccess = true
          }
          .disabled(
            controller.busy
              || (!controller.passwordlessConfigured
                && (controller.enabled || controller.passwordlessAvailable))
          )
          .help("配置前请先关闭合盖运行；移除权限需要管理员授权。")
        }
        Text(controller.status).font(.caption).foregroundStyle(.secondary)
        Text("保持通风，勿放入包中。")
          .font(.caption).foregroundStyle(.orange)
        DisclosureGroup("说明") {
          VStack(alignment: .leading, spacing: 8) {
            Text("仅插电生效，无需外接显示器；拔电或退出后约 10 秒内恢复休眠。")
            Text("开启后会记住开关，下次启动自动尝试开启；手动关闭后取消。")
            Text("合盖约 2 秒后关闭所有屏幕，开盖后用键盘或触控板唤醒。")
            Text("修改全局休眠开关，也会阻止手动休眠；勿与其他防休眠工具同时使用。")
          }
          .foregroundStyle(.secondary).padding(.top, 6)
        }
        .font(.caption)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
    }
    .confirmationDialog("允许插电合盖运行？", isPresented: $confirming, titleVisibility: .visible) {
      Button(controller.passwordlessAvailable || controller.passwordlessConfigured ? "开启" : "授权并开启")
      { controller.setEnabled(true) }
      Button("取消", role: .cancel) {}
    } message: {
      Text("将修改系统休眠开关。未配置免密码权限时需要管理员授权。成功开启后，下次启动软件也会自动尝试开启；手动关闭即可取消。请确保散热，并避免同时运行其他防休眠工具。")
    }
    .confirmationDialog(
      installingAccess ? "配置一次授权免密码开启？" : "移除免密码权限？",
      isPresented: $confirmingAccess, titleVisibility: .visible
    ) {
      Button(installingAccess ? "授权、配置并开启" : "授权并移除") {
        controller.configurePasswordlessAccess(install: installingAccess)
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(
        installingAccess
          ? "将为当前账户安装一条 sudoers 规则，仅允许免密码执行 pmset -a disablesleep 0 和 1。其他以此账户运行的程序也能切换此开关，但不能借此执行任意管理员命令。不保存密码，不安装系统服务。"
          : "将关闭合盖运行及自动开启，并删除 Pi Mac 为当前账户安装的规则。移除需要管理员授权。")
    }
  }
}

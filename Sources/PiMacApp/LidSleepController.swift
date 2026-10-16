import Foundation
import SwiftUI

/// A session-only watchdog, optionally using two narrowly scoped sudo permissions.
@MainActor
final class LidSleepController: ObservableObject {
  static let shared = LidSleepController()
  /// User permission is independent of the watchdog's current health.
  @Published private(set) var requested: Bool
  private enum Phase {
    case inactive, configuring, starting, active, recovering
  }
  @Published private var phase = Phase.inactive
  var enabled: Bool { phase == .active }
  var busy: Bool { phase == .configuring || phase == .starting || phase == .recovering }
  @Published private(set) var status = "未启用" {
    didSet { if status != oldValue { LidSleepDiagnostics.record(status) } }
  }
  @Published private(set) var passwordlessConfigured = false
  @Published private(set) var passwordlessAvailable = false
  private var sessionPasswordless = false
  private var sessionGeneration = UUID()
  private var directory: URL?
  private var timer: Timer?
  private var activationTask: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
  private var recoveryPolicy = LidSleepRecoveryPolicy()
  private let defaults: UserDefaults
  private var launchRestoreTask: Task<Void, Never>?
  private var didRestoreAtLaunch = false
  static let launchPreferenceKey = "PiMac.lidSleep.enableOnLaunch"
  static let requestedPreferenceKey = "PiMac.lidSleep.requested"

  var enableOnLaunch: Bool { defaults.bool(forKey: Self.launchPreferenceKey) }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    requested =
      defaults.object(forKey: Self.requestedPreferenceKey) as? Bool
      ?? defaults.bool(forKey: Self.launchPreferenceKey)
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
      setEnabled(false)
    }
    let script =
      install
      ? LidSleepPasswordlessAccess.installationScript(for: NSUserName())
      : LidSleepPasswordlessAccess.removalScript(for: NSUserName(), restoreSleep: needsRestore)
    guard let script else {
      status = "当前账户名称不适用于免密码规则，未修改系统。"
      return
    }
    phase = .configuring
    let generation = UUID()
    sessionGeneration = generation
    status = install ? "等待一次性管理员授权…" : "正在移除免密码权限…"
    let source = "do shell script \(Self.appleScriptQuote(script)) with administrator privileges"
    activationTask = Task {
      if !install {
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
      }
      guard sessionGeneration == generation, !Task.isCancelled else { return }
      let error = await Task.detached { Self.authorize(source) }.value
      guard sessionGeneration == generation, !Task.isCancelled else { return }
      refreshPasswordlessAccess()
      phase = .inactive
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
    guard enableOnLaunch, requested else { return }
    // Let the previous app's watchdog restore its global switch on quick restarts.
    launchRestoreTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      guard let self, self.enableOnLaunch, self.requested, !self.enabled, !self.busy else { return }
      self.setEnabled(true)
    }
  }

  func setEnabled(_ value: Bool) {
    // 关闭可以撤销尚未完成的开启/重试；旧异步结果由 generation 拦截。
    guard !busy || !value else { return }
    requested = value
    defaults.set(value, forKey: Self.requestedPreferenceKey)
    if !value {
      defaults.set(false, forKey: Self.launchPreferenceKey)
      stop()
      return
    }
    guard !enabled else { return }
    recoveryPolicy = LidSleepRecoveryPolicy()
    activate()
  }

  private func activate() {
    guard directory == nil else {
      status = "旧守护会话尚未释放，请先关闭合盖运行后再重试。"
      return
    }
    phase = .starting
    status = "正在检查免密码权限…"
    let generation = UUID()
    sessionGeneration = generation
    activationTask = Task {
      guard sessionGeneration == generation, !Task.isCancelled else { return }
      let available = await Task.detached {
        LidSleepPasswordlessAccess.existingPermissionAvailable()
      }.value
      guard sessionGeneration == generation, !Task.isCancelled else { return }
      passwordlessAvailable = available
      refreshPasswordlessAccess()
      await startSession(passwordless: available || passwordlessConfigured, generation: generation)
    }
  }

  private func startSession(passwordless: Bool, generation: UUID) async {
    sessionPasswordless = passwordless
    status = passwordless ? "正在免密码开启…" : "等待管理员授权…"
    LidSleepDiagnostics.record(passwordless ? "使用免密码命令权限" : "使用临时管理员授权")
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("pimac-awake-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      directory = folder
      try Data().write(to: folder.appendingPathComponent("lease"))
    } catch {
      stop()
      status = "无法创建守护会话：\(error.localizedDescription)"
      return
    }
    startMonitoring()
    let script = Self.watchdogScript(
      directory: folder.path,
      pid: ProcessInfo.processInfo.processIdentifier, passwordless: passwordless)
    let command = "/bin/sh -c \(Self.shellQuote(script)) </dev/null >/dev/null 2>&1 & echo $!"
    let appleScript =
      "do shell script \(Self.appleScriptQuote(command)) with administrator privileges"
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
    guard sessionGeneration == generation, !Task.isCancelled else { return }
    if let error = result {
      stop()
      status = "未启用：\(error)"
    } else {
      // 只有完整、可信的就绪状态才能记住自动启动偏好；启动中/损坏/失败不能混为一谈。
      for _ in 0..<100 {
        guard sessionGeneration == generation, !Task.isCancelled, let stateDirectory else {
          return
        }
        switch LidSleepSessionObservation.read(directory: stateDirectory, now: .now) {
        case .running(let power):
          phase = .active
          defaults.set(true, forKey: Self.launchPreferenceKey)
          updateStatus(power)
        case .ended(let reason, _):
          stop()
          status =
            reason == .conflict
            ? "系统已由其他工具禁用休眠，请先恢复后再启用。"
            : "守护进程启动失败，请查看诊断日志。"
        case .invalid(let error):
          LidSleepDiagnostics.record(error)
          stop()
          status = "守护状态损坏，已停止会话。"
        case .delayed, .lost:
          try? await Task.sleep(for: .milliseconds(100))
          continue
        }
        break
      }
      guard sessionGeneration == generation, !Task.isCancelled else { return }
      if !enabled {
        stop()
        status = "守护进程未就绪，已取消。"
      }
    }
  }

  func stop() {
    // Session cleanup (including quit/error) must preserve the launch preference.
    if let stateDirectory {
      for name in ["exit", "command-error", "restore-error"] {
        if let text = try? String(
          contentsOf: stateDirectory.appendingPathComponent(name), encoding: .utf8), !text.isEmpty
        {
          LidSleepDiagnostics.record("\(name)：\(text.prefix(2048))")
        }
      }
    }
    sessionGeneration = UUID()
    activationTask?.cancel()
    activationTask = nil
    recoveryTask?.cancel()
    recoveryTask = nil
    phase = .inactive
    launchRestoreTask?.cancel()
    launchRestoreTask = nil
    timer?.invalidate()
    timer = nil
    if let directory {
      // 删除失败时保留会话引用，禁止新会话覆盖旧 helper；再次关闭仍可重试清理。
      do {
        try FileManager.default.removeItem(at: directory)
      } catch {
        if FileManager.default.fileExists(atPath: directory.path) {
          status = "无法释放守护会话：\(error.localizedDescription)；请退出应用以恢复休眠。"
          return
        }
      }
    }
    directory = nil
    status = "已关闭，守护进程将在数秒内恢复休眠"
  }

  private var stateDirectory: URL? {
    guard let directory else { return nil }
    return sessionPasswordless
      ? directory
      : URL(fileURLWithPath: "/private/var/run")
        .appendingPathComponent(directory.lastPathComponent)
  }

  private func startMonitoring() {
    // 定时器只观察状态，不续租。主线程阻塞、App Nap、系统睡眠均不再撤销用户授权。
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.enabled, !self.busy, let stateDirectory = self.stateDirectory else {
          return
        }
        let observation = LidSleepSessionObservation.read(directory: stateDirectory, now: .now)
        switch observation {
        case .running(let power):
          self.recoveryPolicy.healthy(now: .now)
          self.updateStatus(power)
        case .delayed:
          self.status = "正在恢复守护连接，保留合盖运行开关…"
        case .ended, .lost:
          self.recover(observation)
        case .invalid(let error):
          LidSleepDiagnostics.record(error)
          self.stop()
          self.status = "守护状态损坏，已停止会话。"
        }
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func recover(_ observation: LidSleepSessionObservation) {
    guard let stateDirectory else { return }
    let passwordless = sessionPasswordless
    let owned = FileManager.default.fileExists(
      atPath: stateDirectory.appendingPathComponent("owned").path)
    let restored: Bool
    if case .ended(_, let value) = observation { restored = value } else { restored = false }
    LidSleepDiagnostics.record("守护结束：\(observation)，拥有系统开关：\(owned)")
    let delay = recoveryPolicy.nextDelay()
    stop()
    guard directory == nil else { return }
    // 临时管理员授权不做后台弹窗；免密码恢复也必须仍持有本会话的所有权凭据。
    guard requested, passwordless, owned else {
      status = "守护进程失联，已停止会话；若系统仍无法休眠，请运行 sudo pmset -a disablesleep 0"
      return
    }
    phase = .recovering
    status = "正在恢复守护连接，保留合盖运行开关…"
    let generation = sessionGeneration
    recoveryTask = Task {
      // SIGKILL 不会执行 EXIT trap：先恢复全局开关，再开始新的所有权检查。
      // 不对仍存活但更新缓慢的 helper 执行此操作，避免两个会话互相覆盖。
      let error =
        restored
        ? nil
        : await Task.detached {
          Self.run(
            executable: "/usr/bin/sudo",
            arguments: ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
        }.value
      guard sessionGeneration == generation, !Task.isCancelled else { return }
      if let error {
        phase = .inactive
        status = "恢复休眠失败：\(error)"
        return
      }
      guard let delay else {
        phase = .inactive
        status = "守护进程反复退出，已停止自动重试；请检查后重试开启。"
        return
      }
      LidSleepDiagnostics.record("将在 \(delay) 秒后自动重建守护会话")
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard sessionGeneration == generation, requested, !Task.isCancelled else { return }
      activate()
    }
  }

  private func updateStatus(_ state: LidSleepPowerState) {
    switch state {
    case .ac: status = "已插电：合盖保持运行，合盖时请求熄屏"
    case .acClosed: status = "已插电、已合盖：已请求屏幕休眠，电脑继续运行"
    case .acDisplayError: status = "合盖保持运行，但熄屏请求失败"
    case .battery: status = "未插电：使用正常休眠策略"
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

  /// 租约表达会话意愿，不表达 UI 调度速度；退出/崩溃由 PID 与进程启动时间兜底。
  nonisolated static let watchdogLeaseScript = """
    [ -f "$dir/lease" ] || { reason=lease_removed; break; }
    appNow=$(/bin/ps -p "$appPID" -o lstart=)
    [ -n "$appStart" ] && [ "$appNow" = "$appStart" ] || { reason=app_exited; break; }
    """

  nonisolated static func watchdogScript(directory: String, pid: Int32, passwordless: Bool = false)
    -> String
  {
    // 免密码 helper 不提权；仅两个精确的 pmset 命令使用 sudo。
    // 旧授权模式的脚本以内联代码交付，绝不由 root 读取用户可写的脚本。
    let stateDirectory =
      passwordless
      ? directory
      : "/private/var/run/" + URL(fileURLWithPath: directory).lastPathComponent
    let powerCommand = passwordless ? "/usr/bin/sudo -n /usr/bin/pmset" : "/usr/bin/pmset"
    return """
      dir=\(shellQuote(directory))
      stateDir=\(shellQuote(stateDirectory))
      appPID=\(pid)
      umask 022
      \(passwordless ? ":" : "/bin/mkdir -m 755 \"$stateDir\" || exit 1")
      publish() {
        printf '%s\\n' "$1" > "$stateDir/state.tmp" &&
          /bin/mv -f "$stateDir/state.tmp" "$stateDir/state"
      }
      readSetting() {
        settings=$(/usr/bin/pmset -g) || return 1
        printf '%s\\n' "$settings" | /usr/bin/awk '$1 == "SleepDisabled" {print $2; exit}'
      }
      owned=0
      reason=startup_failed
      finish() {
        result=unowned
        if [ "$owned" = 1 ]; then
          # 租约目录可能已被 stop() 删除；恢复系统设置绝不能依赖日志文件能否打开。
          if restoreError=$(\(powerCommand) -a disablesleep 0 2>&1); then
            result=ok
          else
            result=failed
          fi
          if [ -d "$stateDir" ]; then
            printf '%s' "$restoreError" > "$stateDir/restore-error"
          fi
        fi
        if [ -d "$stateDir" ]; then
          printf '%s:%s\\n' "$reason" "$result" > "$stateDir/exit.tmp"
          /bin/mv -f "$stateDir/exit.tmp" "$stateDir/exit"
        fi
        \(passwordless ? ":" : "/bin/sleep 3; /bin/rm -rf \"$stateDir\"")
      }
      trap finish EXIT
      trap 'reason=signal; exit 1' HUP INT TERM
      printf '%s\\n' "$$" > "$stateDir/pid.tmp" &&
        /bin/mv -f "$stateDir/pid.tmp" "$stateDir/pid" || exit 1
      appStart=$(/bin/ps -p "$appPID" -o lstart=)
      [ -f "$dir/lease" ] && [ -n "$appStart" ] || exit 1
      original=$(readSetting) || { reason=power_query_failed; publish error; exit 1; }
      if [ "$original" != 0 ]; then
        if [ "$original" = 1 ]; then
          reason=conflict
          publish conflict
        else
          reason=power_query_failed
          publish error
        fi
        exit 1
      fi
      # 先记录所有权，才能在 SIGKILL 后安全识别本会话是否可能修改了全局开关。
      : > "$stateDir/owned" || exit 1
      owned=1
      reason=app_exited
      while /bin/kill -0 "$appPID" 2>/dev/null; do
        \(watchdogLeaseScript)
        desired=0
        state=battery
        power=$(/usr/bin/pmset -g batt) || { reason=power_query_failed; publish error; exit 1; }
        case "$power" in
          *"Now drawing from 'AC Power'"*) desired=1; state=ac ;;
          *"Now drawing from 'Battery Power'"*) : ;;
          *) reason=power_query_failed; publish error; exit 1 ;;
        esac
        # 每轮重新读取真实系统值，避免唤醒或外部改动后仍相信旧缓存。
        actual=$(readSetting) || { reason=power_query_failed; publish error; exit 1; }
        [ "$actual" = 0 ] || [ "$actual" = 1 ] || {
          reason=power_query_failed; publish error; exit 1;
        }
        if [ "$desired" != "$actual" ]; then
          if ! \(powerCommand) -a disablesleep "$desired" 2>"$stateDir/command-error"; then
            reason=power_failed
            publish error
            exit 1
          fi
        fi
        \(displaySleepScript)
        publish "$state" || { reason=state_write_failed; exit 1; }
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
            get: { controller.requested },
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
        if controller.requested && !controller.enabled && !controller.busy {
          Text("已允许合盖不休眠，但当前未生效。")
            .font(.caption).foregroundStyle(.orange)
          Button("重试开启") { controller.setEnabled(true) }
        }
        Text(controller.status).font(.caption).foregroundStyle(.secondary)
        Text("保持通风，勿放入包中。")
          .font(.caption).foregroundStyle(.orange)
        DisclosureGroup("说明") {
          VStack(alignment: .leading, spacing: 8) {
            Text("仅插电生效，无需外接显示器；拔电或退出后约 10 秒内恢复休眠。")
            Text("勾选表示允许合盖不休眠；运行失败不会取消勾选，是否生效请查看状态。成功开启后，下次启动自动尝试开启；手动关闭后取消。")
            Text("拔电休眠后保留开关，系统唤醒且重新插电时恢复生效；仅插电不保证能唤醒合盖的 Mac。")
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

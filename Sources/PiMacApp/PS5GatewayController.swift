import Foundation
import SwiftUI

struct PS5GatewayStatus: Decodable {
  let phase: String
  let detail: String
  let timestamp: TimeInterval
  let tun: String?

  func isFresh(now: Date = .now) -> Bool {
    let age = now.timeIntervalSince1970 - timestamp
    return age >= -2 && age < 8
  }
}

struct PS5GatewayInspection: Decodable {
  let ready: Bool
  let detail: String
  let addresses: [String]
  let tun: String?
}

enum PS5GatewayCommand {
  static var scriptURL: URL? {
    Bundle.module.url(forResource: "gateway", withExtension: "py", subdirectory: "ps5-gateway")
  }
  static var managedURL: URL? {
    Bundle.module.url(forResource: "managed", withExtension: "py", subdirectory: "ps5-gateway")
  }
  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }
  static func appleScriptQuote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r") + "\""
  }
  static func authorizationScript(source: String, id: String, lease: String, pid: Int32, uid: UInt32) -> String {
    // Pass immutable code inline: root never imports a user-writable Python file or module.
    let validation = "import sys; compile(sys.argv[1], '<gateway>', 'exec')"
    let command = "/usr/bin/python3 -I -c " + shellQuote(validation) + " " + shellQuote(source) + " || exit $?; "
      + "/usr/bin/python3 -I -u -c " + shellQuote(source)
      + " --id " + shellQuote(id) + " --lease " + shellQuote(lease)
      + " --pid \(pid) --uid \(uid) </dev/null >/dev/null 2>&1 & echo $!"
    return "do shell script " + appleScriptQuote(command) + " with administrator privileges"
  }
  static func execute(_ executable: String, arguments: [String]) -> (Int32, String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    do {
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines))
    } catch { return (-1, error.localizedDescription) }
  }
}

@MainActor
final class PS5GatewayController: ObservableObject {
  static let shared = PS5GatewayController()
  enum Phase { case off, checking, ready, authorizing, starting, active, stopping, error }
  @Published private(set) var phase: Phase = .off
  @Published private(set) var detail = "先开启 FlClash 全局模式与 TUN"
  @Published private(set) var addresses: [String] = []
  @Published private(set) var tun = ""
  @Published private(set) var diagnostics = ""
  private var folder: URL?
  private var stateURL: URL?
  private var timer: Timer?
  private var deadline: Date?
  private var authorizationPending = false
  private var stopRequested = false
  private let execute: @Sendable (String, [String]) -> (Int32, String)
  private let readStatus: (URL) -> Data?

  init(
    execute: @escaping @Sendable (String, [String]) -> (Int32, String) = {
      PS5GatewayCommand.execute($0, arguments: $1)
    },
    readStatus: @escaping (URL) -> Data? = { try? Data(contentsOf: $0) }
  ) {
    self.execute = execute
    self.readStatus = readStatus
  }

  var ownsSession: Bool { folder != nil || authorizationPending }
  var restartBlocker: String? { ownsSession ? "PS5 网关会话或授权尚未结束" : nil }
  var title: String {
    switch phase {
    case .off: return "未开启"
    case .checking: return "正在检查"
    case .ready: return "环境就绪"
    case .authorizing: return "等待系统授权"
    case .starting: return "正在启动"
    case .active: return "网关运行中"
    case .stopping: return "正在恢复网络"
    case .error: return "需要处理"
    }
  }

  func inspect() {
    guard !ownsSession, phase != .checking else { return }
    phase = .checking
    Task {
      guard let url = PS5GatewayCommand.scriptURL else {
        fail("缺少内置脚本，请重新安装软件")
        return
      }
      let execute = self.execute
      let result = await Task.detached {
        execute("/usr/bin/python3", ["-I", url.path, "--inspect-json"])
      }.value
      guard !ownsSession else { return }
      diagnostics = result.1
      guard result.0 == 0, let data = result.1.data(using: .utf8),
        let inspection = try? JSONDecoder().decode(PS5GatewayInspection.self, from: data) else {
        fail("检查失败，请展开诊断查看详情")
        return
      }
      addresses = inspection.addresses
      tun = inspection.tun ?? ""
      phase = inspection.ready ? .ready : .error
      detail = inspection.ready ? "FlClash TUN 已就绪，可开启网关" : Self.friendly(inspection.detail)
    }
  }

  func start() {
    guard !ownsSession, phase == .ready else { return }
    do {
      let gateway = try String(contentsOf: PS5GatewayCommand.scriptURL.require(), encoding: .utf8)
      let managed = try String(contentsOf: PS5GatewayCommand.managedURL.require(), encoding: .utf8)
      let source = gateway.components(separatedBy: "\nif __name__ == '__main__':")[0] + "\n" + managed
      let id = UUID().uuidString.lowercased()
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pimac-ps5-" + id)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      try Data().write(to: directory.appendingPathComponent("heartbeat"))
      folder = directory
      stateURL = URL(fileURLWithPath: "/private/var/run/pimac-ps5-\(id)/status.json")
      stopRequested = false
      authorizationPending = true
      phase = .authorizing
      detail = "请在系统弹窗中授权，不保存密码"
      let script = PS5GatewayCommand.authorizationScript(source: source, id: id,
        lease: directory.appendingPathComponent("heartbeat").path,
        pid: ProcessInfo.processInfo.processIdentifier, uid: getuid())
      let heartbeatTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.refreshStatus() }
      }
      timer = heartbeatTimer
      RunLoop.main.add(heartbeatTimer, forMode: .common)
      let execute = self.execute
      Task {
        let result = await Task.detached {
          execute("/usr/bin/osascript", ["-e", script])
        }.value
        authorizationPending = false
        if result.0 != 0 {
          diagnostics = result.1
          finish(error: result.1.contains("-128") ? "授权已取消，未开启网关" : "系统授权失败，请查看诊断")
        } else {
          if !stopRequested { phase = .starting; detail = "正在确认 TUN 与转发参数" }
          deadline = .now.addingTimeInterval(45)
          refreshStatus()
        }
      }
    } catch { fail(error.localizedDescription) }
  }

  func stop() {
    guard ownsSession else { return }
    stopRequested = true
    releaseLease()
    phase = .stopping
    detail = "等待守护进程确认参数已恢复"
    deadline = .now.addingTimeInterval(45)
  }

  func stopAndWait() async -> Bool {
    guard ownsSession else { return true }
    stop()
    for _ in 0..<500 {
      if !ownsSession { return phase != .error }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  func refreshStatus() {
    guard ownsSession else { return }
    if !stopRequested, let folder {
      do { try Data().write(to: folder.appendingPathComponent("heartbeat"), options: .atomic) }
      catch { stop(); diagnostics = error.localizedDescription }
    }
    var confirmedActive = false
    if let url = stateURL, let data = readStatus(url),
      let state = try? JSONDecoder().decode(PS5GatewayStatus.self, from: data) {
      diagnostics = String(decoding: data, as: UTF8.self)
      if state.phase == "stopped" { finish(error: nil); return }
      if state.phase == "error" { finish(error: Self.friendly(state.detail)); return }
      if !stopRequested && state.isFresh() && state.phase == "active" {
        confirmedActive = true
        phase = .active
        detail = "TUN 与 IPv4 转发已确认 · 每秒监测"
        tun = state.tun ?? ""
        deadline = nil
      }
    }
    if !confirmedActive && !stopRequested && phase == .active {
      // Missing, malformed and stale status all revoke the green indicator.
      phase = .starting
      detail = "正在重新确认守护状态"
      deadline = .now.addingTimeInterval(45)
    }
    if !authorizationPending, let deadline, Date.now > deadline {
      stopRequested = true
      releaseLease()
      // Retain ownership so quit/reload cannot claim restoration succeeded.
      phase = .error
      detail = "守护进程未确认恢复，请检查网络参数；可重试停止"
      self.deadline = nil
    }
  }

  private func releaseLease() {
    if let folder { try? FileManager.default.removeItem(at: folder.appendingPathComponent("heartbeat")) }
  }
  private func finish(error: String?) {
    releaseLease()
    if let folder { try? FileManager.default.removeItem(at: folder) }
    folder = nil
    stateURL = nil
    timer?.invalidate()
    timer = nil
    deadline = nil
    phase = error == nil ? .off : .error
    detail = error ?? "网关已停止，所持有的网络参数已恢复"
  }
  private func fail(_ message: String) { phase = .error; detail = message; diagnostics = message }
  static func friendly(_ message: String) -> String {
    if message.contains("App session expired") { return "应用会话已取消或过期，网关未保持运行" }
    if message.contains("Network settings changed") { return "网络参数被其他工具修改，会话已结束" }
    if message.contains("Exactly one") { return "请先启动 FlClash" }
    if message.contains("already enabled") { return "系统转发已开启，请先关闭其他网关或互联网共享" }
    if message.contains("Another gateway") { return "已有网关会话，请先停止原会话" }
    if message.contains("Restore needs attention") { return "网络参数恢复失败，请查看诊断并检查系统设置" }
    if message.contains("TUN") || message.contains("routes") { return "FlClash TUN 未就绪或已变化，会话已停止" }
    return message
  }
}

private extension Optional where Wrapped == URL {
  func require() throws -> URL {
    guard let self else { throw NSError(domain: "PS5Gateway", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "缺少内置网关脚本"]) }
    return self
  }
}

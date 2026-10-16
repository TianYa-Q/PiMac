import Darwin
import Foundation

/// 用户意愿不等于会话健康；未知/损坏状态不能当成“电池模式”继续显示。
enum LidSleepPowerState: String {
  case ac, battery
  case acClosed = "ac_closed"
  case acDisplayError = "ac_display_error"
}

enum LidSleepExitReason: String {
  case startupFailed = "startup_failed"
  case leaseRemoved = "lease_removed"
  case appExited = "app_exited"
  case signal
  case conflict
  case powerFailed = "power_failed"
  case powerQueryFailed = "power_query_failed"
  case stateWriteFailed = "state_write_failed"
}

enum LidSleepSessionObservation: Equatable {
  case running(LidSleepPowerState)
  case delayed
  case ended(reason: LidSleepExitReason, restored: Bool)
  case lost
  case invalid(String)

  static func read(directory: URL, now: Date) -> Self {
    do {
      let exitURL = directory.appendingPathComponent("exit")
      if FileManager.default.fileExists(atPath: exitURL.path) {
        let fields = try String(contentsOf: exitURL, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard fields.count == 2,
          let reason = LidSleepExitReason(rawValue: String(fields[0])),
          ["ok", "failed", "unowned"].contains(String(fields[1]))
        else {
          return .invalid("守护退出记录损坏")
        }
        return .ended(reason: reason, restored: fields[1] == "ok")
      }
      let pidURL = directory.appendingPathComponent("pid")
      guard FileManager.default.fileExists(atPath: pidURL.path) else { return .lost }
      let text = try String(contentsOf: pidURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let pid = Int32(text), pid > 1 else { return .invalid("守护进程 PID 损坏") }
      // SIGKILL 不执行 shell 的 EXIT trap。先检查存活，不能相信尚未过期的旧状态。
      guard kill(pid, 0) == 0 || errno == EPERM else { return .lost }
      let stateURL = directory.appendingPathComponent("state")
      guard FileManager.default.fileExists(atPath: stateURL.path) else { return .delayed }
      let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
      guard let modified = attributes[.modificationDate] as? Date else {
        return .invalid("守护状态缺少更新时间")
      }
      let state = try String(contentsOf: stateURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      // 失败状态先等 EXIT trap 完成恢复，不能因读到中间态抢先删除其诊断文件。
      if state == "error" || state == "conflict" { return .delayed }
      guard let power = LidSleepPowerState(rawValue: state) else {
        return .invalid("未知守护状态：\(state.prefix(80))")
      }
      return now.timeIntervalSince(modified) < 8 ? .running(power) : .delayed
    } catch {
      return .invalid("无法读取守护状态：\(error.localizedDescription)")
    }
  }
}

/// 重试预算跨重建保留，只有持续健康一分钟才重置，避免永久失败时无限循环。
struct LidSleepRecoveryPolicy {
  private var attempts = 0
  private var healthySince: Date?

  mutating func healthy(now: Date) {
    if let healthySince, now.timeIntervalSince(healthySince) >= 60 {
      attempts = 0
    } else if healthySince == nil {
      healthySince = now
    }
  }

  mutating func nextDelay() -> TimeInterval? {
    healthySince = nil
    let delays: [TimeInterval] = [2, 5, 15]
    guard attempts < delays.count else { return nil }
    defer { attempts += 1 }
    return delays[attempts]
  }
}

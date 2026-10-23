import Foundation

/// 直接读取系统事实，不以用户勾选或 helper 的缓存推断是否生效。
enum LidSleepSystemState: Equatable, Sendable {
  case checking
  case available(onAC: Bool, sleepDisabled: Bool)
  case failed(String)

  static func parse(settings: String, battery: String) -> LidSleepSystemState {
    let values = settings.split(separator: "\n").compactMap { line -> String? in
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.first == "SleepDisabled", fields.count == 2 else { return nil }
      return String(fields[1])
    }
    guard values.count == 1, let value = values.first, value == "0" || value == "1" else {
      return .failed("无法识别系统休眠开关")
    }
    let source = battery.components(separatedBy: .newlines).first ?? ""
    switch source {
    case "Now drawing from 'AC Power'":
      return .available(onAC: true, sleepDisabled: value == "1")
    case "Now drawing from 'Battery Power'":
      return .available(onAC: false, sleepDisabled: value == "1")
    default:
      return .failed("无法识别当前电源")
    }
  }

  static func read() -> LidSleepSystemState {
    func query(_ arguments: [String]) throws -> String {
      let process = Process()
      let output = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
      process.arguments = arguments
      process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in
        new
      }
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileReadUnknown)
      }
      return text
    }
    do {
      return parse(settings: try query(["-g"]), battery: try query(["-g", "batt"]))
    } catch {
      return .failed("读取电源状态失败：\(error.localizedDescription)")
    }
  }
}

extension LidSleepSystemState {
  var powerDescription: String {
    switch self {
    case .checking: return "读取中…"
    case .available(let onAC, _): return onAC ? "已插电" : "电池供电"
    case .failed: return "读取失败"
    }
  }

  var sleepDescription: String {
    switch self {
    case .checking: return "读取中…"
    case .available(_, let disabled):
      return disabled ? "休眠已禁用（全局开关）" : "允许正常休眠"
    case .failed(let error): return error
    }
  }

  func managementDescription(requested: Bool, enabled: Bool, busy: Bool) -> String {
    if busy { return "正在应用策略，请稍候…" }
    guard case .available(let onAC, let disabled) = self else {
      return "实际状态未确认，不能保证策略生效"
    }
    let desired = requested && onAC
    if disabled != desired {
      return "状态异常：\(desired ? "应禁用休眠" : "应恢复正常休眠")，请重试"
    }
    if !requested { return "功能已关闭，系统允许休眠" }
    guard enabled else { return "系统开关符合策略，但 PiMac 尚未接管，请重试" }
    return onAC ? "已接管 · 插电合盖不休眠" : "已接管 · 电池供电允许休眠"
  }
}

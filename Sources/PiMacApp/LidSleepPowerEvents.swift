import Darwin
import Foundation
import IOKit.ps

/// 独立于 SwiftUI 主线程运行；这里只发送唤醒事件，不承载权限或电源策略。
/// 提权 shell 不执行用户目录中的程序，只读取有限事件并自行核实系统状态。
enum LidSleepPowerEvents {
  static let argument = "--lid-sleep-power-events"

  static func run(directory: String, parentPID: pid_t) -> Int32 {
    let path = directory + "/events"
    let descriptor = open(path, O_RDWR | O_NONBLOCK | O_NOFOLLOW)
    guard descriptor >= 0 else { return 1 }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { return 1 }
    // O_RDWR 避免等待特权 reader 启动；非阻塞写避免 reader 退出后卡住清理。
    let emit: (String) -> Void = { event in
      let bytes = Array((event + "\n").utf8)
      let count = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
      if count != bytes.count { exit(1) }
    }
    let context = EventContext(emit: emit)
    guard
      let source = IOPSNotificationCreateRunLoopSource(
        { pointer in
          guard let pointer else { return }
          Unmanaged<EventContext>.fromOpaque(pointer).takeUnretainedValue().emit("power")
        }, Unmanaged.passUnretained(context).toOpaque())
    else { return 1 }
    let loop = CFRunLoopGetCurrent()
    CFRunLoopAddSource(loop, source.takeRetainedValue(), .defaultMode)
    // 这里只保护监听进程自身的生命周期；不轮询电源，也不发送策略事件。
    let timer = Timer(timeInterval: 2, repeats: true) { _ in
      guard kill(parentPID, 0) == 0,
        FileManager.default.fileExists(atPath: directory + "/lease")
      else { exit(0) }
    }
    RunLoop.current.add(timer, forMode: .default)
    emit("power")
    withExtendedLifetime(context) { CFRunLoopRun() }
    return 1
  }

  private final class EventContext {
    let emit: (String) -> Void
    init(emit: @escaping (String) -> Void) { self.emit = emit }
  }
}

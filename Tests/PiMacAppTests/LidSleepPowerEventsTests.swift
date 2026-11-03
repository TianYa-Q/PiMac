import Darwin
import Foundation
import Testing

@testable import PiMacApp

struct LidSleepPowerEventsTests {
  @Test func nativeListenerPublishesInitialEventAndExitsWhenLeaseIsRemoved() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let directory = root.appendingPathComponent("tmp/lid-sleep-events/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lease = directory.appendingPathComponent("lease")
    try Data().write(to: lease)
    let fifo = directory.appendingPathComponent("events").path
    #expect(mkfifo(fifo, 0o600) == 0)
    let descriptor = open(fifo, O_RDWR | O_NONBLOCK)
    #expect(descriptor >= 0)
    defer { close(descriptor) }
    let process = Process()
    process.executableURL = root.appendingPathComponent(".build/debug/PiMac")
    process.arguments = [
      LidSleepPowerEvents.argument, directory.path,
      String(ProcessInfo.processInfo.processIdentifier),
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    // 仅启动原生通知入口：不会启动 GUI，也绝不调用 pmset 或改变实际电源策略。
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
      let trash = Process()
      trash.executableURL = URL(fileURLWithPath: "/usr/bin/trash")
      trash.arguments = [directory.path]
      try? trash.run()
      trash.waitUntilExit()
    }
    var received = Data()
    let deadline = Date().addingTimeInterval(5)
    while received.isEmpty, process.isRunning, Date() < deadline {
      var bytes = [UInt8](repeating: 0, count: 128)
      let count = read(descriptor, &bytes, bytes.count)
      if count > 0 { received.append(contentsOf: bytes.prefix(count)) }
      if received.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
    }
    #expect(String(data: received, encoding: .utf8)?.hasPrefix("power\n") == true)
    try FileManager.default.moveItem(at: lease, to: directory.appendingPathComponent("released"))
    let exitDeadline = Date().addingTimeInterval(4)
    while process.isRunning, Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.05) }
    #expect(!process.isRunning)
    if !process.isRunning { #expect(process.terminationStatus == 0) }
  }
}

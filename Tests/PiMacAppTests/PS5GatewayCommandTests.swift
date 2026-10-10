import Foundation
import Testing

@testable import PiMacApp

struct PS5GatewayCommandTests {
  @Test func resourcesCompileAsInlineIsolatedProgram() throws {
    let url = try #require(PS5GatewayCommand.scriptURL)
    let managed = try #require(PS5GatewayCommand.managedURL)
    let gateway = try String(contentsOf: url, encoding: .utf8)
    let source = gateway.components(separatedBy: "\nif __name__ == '__main__':")[0]
      + "\n" + (try String(contentsOf: managed, encoding: .utf8))
    let result = PS5GatewayCommand.execute("/usr/bin/python3", arguments: [
      "-I", "-c", "import sys; compile(sys.argv[1], '<gateway>', 'exec')", source,
    ])
    #expect(result.0 == 0)
    #expect(source.contains("session.stop()"))
    #expect(source.contains("os.O_NOFOLLOW"))
  }

  @Test func shellQuotePreservesUntrustedPath() throws {
    let path = "/tmp/a'b \"$HOME; echo nope\\\n/gateway.py"
    let result = PS5GatewayCommand.execute("/bin/sh", arguments: [
      "-c", "printf %s " + PS5GatewayCommand.shellQuote(path),
    ])
    #expect(result.0 == 0)
    #expect(result.1 == path)
  }

  @Test func authorizationUsesInlineCodeNotTerminalOrUserModule() {
    let script = PS5GatewayCommand.authorizationScript(source: "print('test')\n", id: "test",
      lease: "/tmp/a'b", pid: 123, uid: 501)
    #expect(script.hasPrefix("do shell script "))
    #expect(script.hasSuffix(" with administrator privileges"))
    #expect(script.contains("-I -u -c"))
    #expect(script.contains("echo $!"))
    #expect(!script.contains("Terminal"))
    #expect(!script.contains("sudo"))
    #expect(!script.contains("gateway.py"))
  }

  @Test func appleScriptQuoteEscapesNewlinesAndQuotes() {
    #expect(PS5GatewayCommand.appleScriptQuote("a\"b\\c\nd\re") == "\"a\\\"b\\\\c\\nd\\re\"")
  }

  @Test func staleOrFutureHeartbeatCannotShowActive() throws {
    let now = Date(timeIntervalSince1970: 100)
    for (stamp, expected) in [(100.0, true), (95, true), (90, false), (103, false)] {
      let data = Data("{\"phase\":\"active\",\"detail\":\"\",\"timestamp\":\(stamp),\"tun\":\"utun4\"}".utf8)
      let status = try JSONDecoder().decode(PS5GatewayStatus.self, from: data)
      #expect(status.isFresh(now: now) == expected)
    }
  }

  private static func fakeExecute(_ executable: String, _ arguments: [String]) -> (Int32, String) {
    if executable == "/usr/bin/python3" {
      return (0, "{\"ready\":true,\"detail\":\"\",\"addresses\":[\"en0: 192.168.0.10\"],\"tun\":\"utun4\"}")
    }
    return (0, "123")
  }

  private static func snapshot(_ phase: String, age: TimeInterval = 0) -> Data {
    Data("{\"phase\":\"\(phase)\",\"detail\":\"\",\"timestamp\":\(Date.now.timeIntervalSince1970 - age),\"tun\":\"utun4\"}".utf8)
  }

  @Test @MainActor func missingMalformedOrStaleStatusRevokesGreenAndStopWaitsForRestore() async throws {
    var state: Data? = nil
    let controller = PS5GatewayController(
      execute: { Self.fakeExecute($0, $1) }, readStatus: { _ in state })
    defer {
      state = Self.snapshot("stopped")
      controller.stop()
      controller.refreshStatus()
    }
    controller.inspect()
    for _ in 0..<100 where controller.phase == .checking {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(controller.phase == .ready)
    controller.start()
    for _ in 0..<100 where controller.phase == .authorizing {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(controller.phase == .starting)
    #expect(controller.restartBlocker != nil)
    for invalid in [nil, Data("invalid json".utf8), Self.snapshot("active", age: 30)] {
      state = Self.snapshot("active")
      controller.refreshStatus()
      #expect(controller.phase == .active)
      state = invalid
      controller.refreshStatus()
      #expect(controller.phase == .starting)
    }
    state = Self.snapshot("active")
    controller.refreshStatus()
    controller.stop()
    controller.refreshStatus()
    #expect(controller.phase == .stopping)
    #expect(controller.ownsSession)
    state = Self.snapshot("stopped")
    controller.refreshStatus()
    #expect(controller.phase == .off)
    #expect(!controller.ownsSession)
    #expect(controller.restartBlocker == nil)
  }

  @Test @MainActor func cancelledSystemAuthorizationReleasesSessionWithoutGreenStatus() async throws {
    let controller = PS5GatewayController(execute: { executable, arguments in
      if executable == "/usr/bin/osascript" { return (1, "User canceled. (-128)") }
      return Self.fakeExecute(executable, arguments)
    })
    controller.inspect()
    for _ in 0..<100 where controller.phase == .checking {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(controller.phase == .ready)
    controller.start()
    for _ in 0..<100 where controller.phase == .authorizing {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(controller.phase == .error)
    #expect(controller.detail.contains("授权已取消"))
    #expect(!controller.ownsSession)
    #expect(controller.restartBlocker == nil)
  }

  @Test @MainActor func idleControllerDoesNotBlockRestartOrRequestAuthorization() {
    let controller = PS5GatewayController()
    #expect(controller.phase == .off)
    #expect(controller.restartBlocker == nil)
    controller.start() // Must inspect and reach ready before requesting authorization.
    #expect(!controller.ownsSession)
    controller.stop()
    #expect(controller.phase == .off)
  }
}

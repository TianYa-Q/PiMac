import Darwin
import Foundation

@testable import PiMacApp

/// 同步启动窗口内注入隔离环境，Process 复制后立即恢复，不跨 await 保持全局环境。
/// MainActor 串行化各 Swift fixture 的启动；正式服务及其能力默认值完全不变。
@MainActor
func startT3ProtocolFixture(
  service: T3BridgeService, workspace: WorkspaceModel, stateDirectory: URL,
  binary: URL?, model: String
) throws {
  let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let helper = repository.appendingPathComponent(
    "sidecars/t3-server/tests/fixtures/protocol-server.mjs")
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/zsh")
  process.arguments = [
    "-lc", "exec node \"$1\" --prepare \"$2\" \"$3\" \"$4\"", "pimac-test-fixture",
    helper.path, stateDirectory.path, binary?.path ?? "", model,
  ]
  let inheritedKeys: Set<String> = [
    "PATH", "TMPDIR", "TMP", "TEMP", "LANG", "LC_ALL", "TZ", "SystemRoot", "WINDIR",
  ]
  var preparationEnvironment = ProcessInfo.processInfo.environment.filter {
    inheritedKeys.contains($0.key)
  }
  preparationEnvironment["HOME"] = stateDirectory.appendingPathComponent("fixture-home").path
  process.environment = preparationEnvironment
  let output = Pipe()
  process.standardOutput = output
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0,
    let environment = try JSONSerialization.jsonObject(with: data) as? [String: String]
  else {
    throw NSError(
      domain: "T3ProtocolFixture", code: Int(process.terminationStatus),
      userInfo: [NSLocalizedDescriptionKey: "Failed to prepare isolated Server fixture"])
  }
  let previous = ProcessInfo.processInfo.environment
  defer {
    for key in ProcessInfo.processInfo.environment.keys { unsetenv(key) }
    for (key, value) in previous { setenv(key, value, 1) }
  }
  for key in previous.keys { unsetenv(key) }
  for (key, value) in environment { setenv(key, value, 1) }
  // 除 Provider 实例外，CodexInstallation 的独立 --version 探测也必须使用
  // fixture PATH/home，不能运行开发者二进制或继承其凭据。
  try service.start(
    workspace: workspace, token: T3NetworkEndpoint.secret(), stateDirectory: stateDirectory)
}

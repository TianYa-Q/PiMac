import Foundation

final class PiRPCClient {
  typealias JSON = [String: Any]

  var onEvent: ((JSON) -> Void)?
  var onErrorOutput: ((String) -> Void)?
  var onLog: ((String) -> Void)?
  var onTermination: ((Int32) -> Void)?

  private var process: Process?
  private var input: FileHandle?
  private var outputHandle: FileHandle?
  private var errorHandle: FileHandle?
  private struct PendingResponse {
    let command: String
    let startedAt: Date
    let completion: (Result<JSON, Error>) -> Void
    let deadline: DispatchWorkItem?
  }

  private var pendingResponses: [String: PendingResponse] = [:]

  var pendingRequestSummary: String {
    let now = Date()
    return pendingResponses.values.sorted { $0.startedAt < $1.startedAt }
      .map { "\($0.command)（\(Int(now.timeIntervalSince($0.startedAt))) 秒）" }
      .joined(separator: "、")
  }
  private let readQueue = DispatchQueue(label: "com.jianfeng.pi-mac.rpc-reader")
  private var writeQueue = DispatchQueue(label: "com.jianfeng.pi-mac.rpc-writer")
  /// Identifies the current child process so data already queued by an old pipe cannot be
  /// decoded as output from its replacement.
  private var processGeneration = UUID()

  var isRunning: Bool { process?.isRunning == true }

  func start(
    piPath: String, workingDirectory: URL, continueLastSession: Bool = true,
    fastMode: Bool = false
  ) throws {
    stop()

    let process = Process()
    let generation = UUID()
    processGeneration = generation
    // A blocked old pipe must never hold up commands to a replacement process.
    writeQueue = DispatchQueue(label: "com.jianfeng.pi-mac.rpc-writer.\(generation)")
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    // Decoders belong to this pair of pipes. Keeping them local prevents a trailing partial
    // record from a stopped process being combined with output from a replacement process.
    let outputDecoder = JSONLineDecoder()
    let errorDecoder = JSONLineDecoder()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    // 登录 shell 能拿到 GUI 应用通常缺失的 Node/pnpm PATH；不要启用交互模式（-i）。
    // 从终端用 `swift run` 启动时，后台的交互式 shell 会因读取控制终端而收到
    // SIGTTIN 并暂停，表现为所有 RPC 请求永久无响应。
    // Pi 路径作为参数传入，避免命令注入。
    let sessionArgument = continueLastSession ? " --continue" : ""
    guard let extensionURL = Bundle.module.url(forResource: "pimac-fast", withExtension: "ts")
    else {
      throw RPCError.commandFailed("缺少 Fast 模式扩展资源，请重新安装 Pi Mac")
    }
    process.arguments = [
      "-lc", "exec \"$1\" --mode rpc\(sessionArgument) --extension \"$2\"",
      "pi-macos", piPath, extensionURL.path,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["PIMAC_FAST_MODE"] = fastMode ? "1" : "0"
    process.environment = environment
    process.currentDirectoryURL = workingDirectory
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.readQueue.async { [weak self] in
        guard let self else { return }
        for record in outputDecoder.append(data) {
          self.decode(record, generation: generation)
        }
      }
    }
    errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.readQueue.async { [weak self] in
        guard let self else { return }
        for record in errorDecoder.append(data) {
          let text = String(decoding: record, as: UTF8.self)
          Task { @MainActor [weak self] in
            guard self?.processGeneration == generation else { return }
            self?.onErrorOutput?(text)
          }
        }
      }
    }
    process.terminationHandler = { [weak self] process in
      DispatchQueue.main.async { [weak self] in
        guard let self, self.process === process,
          self.processGeneration == generation
        else { return }
        self.input = nil
        self.process = nil
        self.outputHandle?.readabilityHandler = nil
        self.errorHandle?.readabilityHandler = nil
        self.outputHandle = nil
        self.errorHandle = nil
        self.failPendingResponses(RPCError.processTerminated(process.terminationStatus))
        self.onTermination?(process.terminationStatus)
      }
    }

    try process.run()
    onLog?("Pi RPC 进程已启动，PID \(process.processIdentifier)")
    self.process = process
    input = inputPipe.fileHandleForWriting
    outputHandle = outputPipe.fileHandleForReading
    errorHandle = errorPipe.fileHandleForReading
  }

  func stop() {
    processGeneration = UUID()
    let stoppedProcess = process
    self.process = nil
    outputHandle?.readabilityHandler = nil
    errorHandle?.readabilityHandler = nil
    outputHandle = nil
    errorHandle = nil
    let stoppedInput = input
    input = nil
    writeQueue.async { try? stoppedInput?.close() }
    if let stoppedProcess, stoppedProcess.isRunning {
      // EOF requests orderly disposal (including MCP children). Bound shutdown even if
      // an extension ignores EOF or SIGTERM; never signal a replacement process.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        if stoppedProcess.isRunning { stoppedProcess.terminate() }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        if stoppedProcess.isRunning { kill(stoppedProcess.processIdentifier, SIGKILL) }
      }
    }
    failPendingResponses(RPCError.cancelled)
  }

  private func failPendingResponses(_ error: Error) {
    let pending = pendingResponses
    pendingResponses.removeAll()
    for response in pending.values {
      response.deadline?.cancel()
      response.completion(.failure(error))
    }
  }

  /// Inspection commands have bounded deadlines. Mutating commands can wait for
  /// extension dialogs, compaction or abort, so they have no implicit timeout.
  static func defaultTimeout(for command: String) -> TimeInterval? {
    command.hasPrefix("get_") ? 30 : nil
  }

  @discardableResult
  func request(
    _ command: JSON,
    timeout: TimeInterval? = nil,
    completion: ((Result<JSON, Error>) -> Void)? = nil
  ) -> String? {
    guard let input, isRunning else {
      completion?(.failure(RPCError.notRunning))
      return nil
    }

    var payload = command
    let id = (payload["id"] as? String) ?? UUID().uuidString
    payload["id"] = id
    guard JSONSerialization.isValidJSONObject(payload),
      var data = try? JSONSerialization.data(withJSONObject: payload)
    else {
      completion?(.failure(RPCError.invalidCommand))
      return nil
    }
    data.append(0x0A)
    guard pendingResponses[id] == nil else {
      completion?(.failure(RPCError.commandFailed("重复的 RPC 请求 ID：\(id)")))
      return nil
    }
    if let completion {
      let name = payload["type"] as? String ?? "unknown"
      let generation = processGeneration
      let interval = timeout ?? Self.defaultTimeout(for: name)
      let deadline = interval.map { _ in
        DispatchWorkItem { [weak self] in
          guard let self, self.processGeneration == generation,
            let pending = self.pendingResponses.removeValue(forKey: id)
          else { return }
          pending.completion(.failure(RPCError.timedOut(name)))
        }
      }
      pendingResponses[id] = PendingResponse(
        command: name, startedAt: Date(), completion: completion, deadline: deadline)
      if let interval, let deadline {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, interval), execute: deadline)
      }
    }

    let generation = processGeneration
    let bytes = data
    // Serial writes preserve JSONL order and honor pipe backpressure without blocking UI.
    writeQueue.async { [weak self] in
      do { try input.write(contentsOf: bytes) } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self, self.processGeneration == generation else { return }
          if let pending = self.pendingResponses.removeValue(forKey: id) {
            pending.deadline?.cancel()
            pending.completion(.failure(error))
          } else if completion == nil {
            self.onErrorOutput?("写入 Pi 失败：\(error.localizedDescription)")
          }
        }
      }
    }
    onLog?("→ \(payload["type"] as? String ?? "unknown") [\(id)]")
    return id
  }

  func sendExtensionResponse(_ response: JSON) {
    _ = request(response)
  }

  private func decode(_ data: Data, generation: UUID) {
    do {
      guard let event = try JSONSerialization.jsonObject(with: data) as? JSON else {
        throw RPCError.invalidResponse
      }
      DispatchQueue.main.async { [weak self] in
        guard self?.processGeneration == generation else { return }
        self?.receive(event, byteCount: data.count)
      }
    } catch {
      let text = String(decoding: data, as: UTF8.self)
      DispatchQueue.main.async { [weak self] in
        guard self?.processGeneration == generation else { return }
        self?.onErrorOutput?("无法解析 Pi 输出：\(text)")
      }
    }
  }

  private func receive(_ event: JSON, byteCount: Int) {
    let type = event["type"] as? String ?? "unknown"
    let id = event["id"] as? String
    if type == "response" {
      let size = byteCount >= 1_000_000 ? "，\(byteCount) bytes" : ""
      onLog?("← response/\(event["command"] as? String ?? "unknown") [\(id ?? "无 ID")]\(size)")
    } else if type != "message_update" && type != "tool_execution_update"
      && !(type == "extension_ui_request" && event["method"] as? String == "setStatus")
    {
      // Extensions use setStatus as a lightweight state stream. Quota countdowns in
      // particular can emit it periodically from every RPC process; it is not a dialog or
      // proof that a provider request was made, so do not flood the diagnostic log with it.
      onLog?("← \(type)")
    }

    if type == "response",
      let id = event["id"] as? String,
      let pending = pendingResponses.removeValue(forKey: id)
    {
      pending.deadline?.cancel()
      if event["success"] as? Bool == true {
        pending.completion(.success(event))
      } else {
        pending.completion(.failure(RPCError.commandFailed(event["error"] as? String ?? "未知错误")))
      }
      return
    }
    onEvent?(event)
  }
}

enum RPCError: LocalizedError {
  case notRunning
  case cancelled
  case timedOut(String)
  case invalidCommand
  case invalidResponse
  case processTerminated(Int32)
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .notRunning: "Pi 尚未启动"
    case .cancelled: "RPC 请求已取消（进程停止或重启）"
    case .timedOut(let command): "等待 Pi 响应超时：\(command)"
    case .invalidCommand: "无法编码 RPC 命令"
    case .invalidResponse: "Pi 返回了无效数据"
    case .processTerminated(let code): "Pi 进程已退出（\(code)）"
    case .commandFailed(let message): message
    }
  }
}

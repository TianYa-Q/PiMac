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
  private var pendingResponses: [String: (Result<JSON, Error>) -> Void] = [:]
  private let readQueue = DispatchQueue(label: "com.jianfeng.pi-mac.rpc-reader")
  /// Identifies the current child process so data already queued by an old pipe cannot be
  /// decoded as output from its replacement.
  private var processGeneration = UUID()

  var isRunning: Bool { process?.isRunning == true }

  func start(piPath: String, workingDirectory: URL, continueLastSession: Bool = true) throws {
    stop()

    let process = Process()
    let generation = UUID()
    processGeneration = generation
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
    process.arguments = ["-lc", "exec \"$1\" --mode rpc\(sessionArgument)", "pi-macos", piPath]
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
        let error = RPCError.processTerminated(process.terminationStatus)
        for response in self.pendingResponses.values {
          response(.failure(error))
        }
        self.pendingResponses.removeAll()
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
    pendingResponses.removeAll()
    guard let process else { return }
    outputHandle?.readabilityHandler = nil
    errorHandle?.readabilityHandler = nil
    outputHandle = nil
    errorHandle = nil
    input?.closeFile()
    if process.isRunning {
      process.terminate()
    }
    self.process = nil
    input = nil
  }

  @discardableResult
  func request(
    _ command: JSON,
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
    if let completion {
      pendingResponses[id] = completion
    }

    do {
      try input.write(contentsOf: data)
      onLog?("→ \(payload["type"] as? String ?? "unknown") [\(id)]")
      return id
    } catch {
      pendingResponses.removeValue(forKey: id)
      completion?(.failure(error))
      return nil
    }
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
        self?.receive(event)
      }
    } catch {
      let text = String(decoding: data, as: UTF8.self)
      DispatchQueue.main.async { [weak self] in
        guard self?.processGeneration == generation else { return }
        self?.onErrorOutput?("无法解析 Pi 输出：\(text)")
      }
    }
  }

  private func receive(_ event: JSON) {
    let type = event["type"] as? String ?? "unknown"
    let id = event["id"] as? String
    if type == "response" {
      onLog?("← response/\(event["command"] as? String ?? "unknown") [\(id ?? "无 ID")]")
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
      let completion = pendingResponses.removeValue(forKey: id)
    {
      if event["success"] as? Bool == true {
        completion(.success(event))
      } else {
        completion(.failure(RPCError.commandFailed(event["error"] as? String ?? "未知错误")))
      }
      return
    }
    onEvent?(event)
  }
}

enum RPCError: LocalizedError {
  case notRunning
  case invalidCommand
  case invalidResponse
  case processTerminated(Int32)
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .notRunning: "Pi 尚未启动"
    case .invalidCommand: "无法编码 RPC 命令"
    case .invalidResponse: "Pi 返回了无效数据"
    case .processTerminated(let code): "Pi 进程已退出（\(code)）"
    case .commandFailed(let message): message
    }
  }
}

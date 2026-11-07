import Darwin
import Foundation

/// 完整诊断仅写本机私有文件，不进入 UI 摘要；串行落盘避免大转录阻塞主线程。
/// 单文件最多 64 MiB，另留最多 3 份归档；过量历史移入废纸篓，不覆盖或截断正文。
enum SessionDiagnostics {
  static let url = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/PiMac/Logs/session-diagnostics.log")
  private static let queue = DispatchQueue(label: "PiMac.session-diagnostics", qos: .utility)
  // 仅由串行诊断队列访问；启动检查一次，其后只在轮转时扫描目录。
  private static var checkedRetention = false

  static func record(_ event: String, id: String, fields: [String: Any]) {
    queue.async {
      do {
        try append(
          event, id: id, fields: fields, destination: url, checkRetention: !checkedRetention)
        checkedRetention = true
      } catch {
        NSLog("Session diagnostics write failed: %@", String(reflecting: error))
      }
    }
  }

  static func errorFields(_ error: Error) -> [String: Any] {
    let value = error as NSError
    return [
      "type": String(reflecting: type(of: error)), "description": String(reflecting: error),
      "domain": value.domain, "code": value.code, "userInfo": String(reflecting: value.userInfo),
    ]
  }

  static func append(
    _ event: String, id: String, fields: [String: Any], destination: URL,
    maxFileBytes: Int = 64 * 1024 * 1024, maxArchives: Int = 3, checkRetention: Bool = true
  ) throws {
    let entry: [String: Any] = [
      "timestamp": ISO8601DateFormatter().string(from: .now), "event": event,
      "id": id, "pid": ProcessInfo.processInfo.processIdentifier, "fields": fields,
    ]
    var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
    data.append(10)
    // 单条超过预算时明确报错，不制造超大文件，也不写半条/截断的诊断。
    guard maxFileBytes > 0, maxArchives >= 0, data.count <= maxFileBytes else {
      throw CocoaError(.fileWriteOutOfSpace)
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = Darwin.open(destination.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var descriptor = fd
    defer { Darwin.close(descriptor) }
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == getuid(), status.st_mode & 0o077 == 0, status.st_nlink == 1
    else { throw CocoaError(.fileWriteNoPermission) }
    if checkRetention {
      try pruneArchives(
        destination: destination, maxFileBytes: maxFileBytes, maxArchives: maxArchives)
    }
    if status.st_size + Int64(data.count) > maxFileBytes {
      try FileManager.default.moveItem(
        at: destination, to: destination.appendingPathExtension(UUID().uuidString))
      Darwin.close(fd)
      descriptor = Darwin.open(
        destination.path, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      try pruneArchives(
        destination: destination, maxFileBytes: maxFileBytes, maxArchives: maxArchives)
    }
    // POSIX write 允许短写；不能将半条诊断当作成功。
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        offset += count
      }
    }
  }

  private static func pruneArchives(destination: URL, maxFileBytes: Int, maxArchives: Int) throws {
    let manager = FileManager.default
    let prefix = destination.lastPathComponent + "."
    let files = try manager.contentsOfDirectory(
      at: destination.deletingLastPathComponent(), includingPropertiesForKeys: nil)
    var archives: [(url: URL, modified: Date, bytes: Int64)] = []
    for file in files {
      let name = file.lastPathComponent
      // 只管理本 logger 生成的 UUID 归档，不碰同目录其他文件，也不跟随符号链接。
      guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
      else { continue }
      var status = stat()
      guard lstat(file.path, &status) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == getuid(),
        status.st_mode & 0o077 == 0, status.st_nlink == 1
      else { throw CocoaError(.fileWriteNoPermission) }
      archives.append(
        (
          file,
          Date(
            timeIntervalSince1970: Double(status.st_mtimespec.tv_sec)
              + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000), status.st_size
        ))
    }
    archives.sort {
      $0.modified == $1.modified
        ? $0.url.lastPathComponent > $1.url.lastPathComponent : $0.modified > $1.modified
    }
    var retainedBytes: Int64 = 0
    var retainedCount = 0
    let budget = Int64(maxFileBytes) * Int64(maxArchives)
    for archive in archives {
      if retainedCount < maxArchives, archive.bytes <= maxFileBytes,
        archive.bytes <= budget - retainedBytes
      {
        retainedBytes += archive.bytes
        retainedCount += 1
      } else {
        // 包含旧版本遗留的超大归档；移动失败必须抛出，不能宣称已收敛。
        try manager.trashItem(at: archive.url, resultingItemURL: nil)
      }
    }
  }
}

final class SessionRequestDiagnostics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let id: String
  init(id: String) { self.id = id }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    SessionDiagnostics.record(
      "http.metrics", id: id,
      fields: [
        "taskID": task.taskIdentifier, "interval": metrics.taskInterval.duration,
        "redirectCount": metrics.redirectCount,
        "transactions": metrics.transactionMetrics.map { metric -> [String: Any] in
          var fields: [String: Any] = [
            "url": metric.request.url?.absoluteString ?? "",
            "protocol": metric.networkProtocolName ?? "",
            "proxy": metric.isProxyConnection, "reused": metric.isReusedConnection,
            "resourceFetchType": metric.resourceFetchType.rawValue,
            "localAddress": metric.localAddress ?? "", "localPort": metric.localPort ?? 0,
            "remoteAddress": metric.remoteAddress ?? "", "remotePort": metric.remotePort ?? 0,
            "requestHeaderBytes": metric.countOfRequestHeaderBytesSent,
            "requestBodyBytes": metric.countOfRequestBodyBytesSent,
            "responseHeaderBytes": metric.countOfResponseHeaderBytesReceived,
            "responseBodyBytes": metric.countOfResponseBodyBytesReceived,
          ]
          for (key, date) in [
            ("fetchStart", metric.fetchStartDate), ("dnsStart", metric.domainLookupStartDate),
            ("dnsEnd", metric.domainLookupEndDate), ("connectStart", metric.connectStartDate),
            ("connectEnd", metric.connectEndDate), ("tlsStart", metric.secureConnectionStartDate),
            ("tlsEnd", metric.secureConnectionEndDate), ("requestStart", metric.requestStartDate),
            ("requestEnd", metric.requestEndDate), ("responseStart", metric.responseStartDate),
            ("responseEnd", metric.responseEndDate),
          ] {
            if let date { fields[key] = date.timeIntervalSince1970 }
          }
          return fields
        },
      ])
  }
}

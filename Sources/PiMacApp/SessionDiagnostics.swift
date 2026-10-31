import Darwin
import Foundation

/// 完整诊断仅写本机私有文件，不进入 UI 摘要；串行落盘避免大转录阻塞主线程。
/// 不截断正文，也不覆盖旧日志；到达单文件预算后使用唯一名称归档。
enum SessionDiagnostics {
  static let url = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/PiMac/Logs/session-diagnostics.log")
  private static let queue = DispatchQueue(label: "PiMac.session-diagnostics", qos: .utility)

  static func record(_ event: String, id: String, fields: [String: Any]) {
    queue.async {
      do {
        try append(event, id: id, fields: fields, destination: url)
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
    _ event: String, id: String, fields: [String: Any], destination: URL
  ) throws {
    let entry: [String: Any] = [
      "timestamp": ISO8601DateFormatter().string(from: .now), "event": event,
      "id": id, "pid": ProcessInfo.processInfo.processIdentifier, "fields": fields,
    ]
    var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
    data.append(10)
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
    if status.st_size + Int64(data.count) > 64 * 1024 * 1024 {
      try FileManager.default.moveItem(
        at: destination, to: destination.appendingPathExtension(UUID().uuidString))
      Darwin.close(fd)
      descriptor = Darwin.open(
        destination.path, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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

import Foundation

/// 严格按 LF 拆分 Pi RPC 的 JSONL 数据，避免把 JSON 字符串中的 Unicode 行分隔符误判成协议边界。
final class JSONLineDecoder {
  private var buffer = Data()
  private let maxRecordBytes: Int
  private var discardingRecord = false
  private(set) var droppedRecordCount = 0

  init(maxRecordBytes: Int = 16 * 1024 * 1024) {
    precondition(maxRecordBytes > 0)
    self.maxRecordBytes = maxRecordBytes
  }

  /// Oversized records are discarded through their next LF; later records remain usable.
  func append(_ data: Data) -> [Data] {
    var records: [Data] = []
    // A get_messages response can span many pipe reads. Only scan the new bytes: rescanning
    // the unfinished record on every read makes large JSONL records quadratic in size.
    data.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      guard let base = bytes.baseAddress else { return }
      var recordStart = 0
      // libc 按字节块寻找 LF，避免在多 MiB 的单行工具结果上逐字节执行 Swift 循环。
      // 只搜索本次新增数据，保留丢弃超限记录直到下一个 LF 的恢复边界。
      while recordStart < bytes.count,
        let newline = memchr(base.advanced(by: recordStart), 0x0A, bytes.count - recordStart)
      {
        let index = base.distance(to: UnsafePointer(newline.assumingMemoryBound(to: UInt8.self)))
        appendFragment(base.advanced(by: recordStart), count: index - recordStart)
        if !discardingRecord {
          if buffer.last == 0x0D { buffer.removeLast() }
          if !buffer.isEmpty { records.append(buffer) }
        }
        buffer = Data()
        discardingRecord = false
        recordStart = index + 1
      }
      appendFragment(base.advanced(by: recordStart), count: bytes.count - recordStart)
    }
    return records
  }

  private func appendFragment(_ bytes: UnsafePointer<UInt8>, count: Int) {
    guard !discardingRecord else { return }
    guard count <= maxRecordBytes - buffer.count else {
      buffer = Data()
      discardingRecord = true
      droppedRecordCount += 1
      return
    }
    buffer.append(bytes, count: count)
  }

  func finish() -> Data? {
    defer {
      buffer.removeAll(keepingCapacity: false)
      discardingRecord = false
    }
    guard !discardingRecord, !buffer.isEmpty else { return nil }
    if buffer.last == 0x0D {
      buffer.removeLast()
    }
    return buffer.isEmpty ? nil : buffer
  }
}

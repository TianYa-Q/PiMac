import Foundation

/// 严格按 LF 拆分 Pi RPC 的 JSONL 数据，避免把 JSON 字符串中的 Unicode 行分隔符误判成协议边界。
final class JSONLineDecoder {
  private var buffer = Data()

  func append(_ data: Data) -> [Data] {
    var records: [Data] = []
    // A get_messages response can span many pipe reads. Only scan the new bytes: rescanning
    // the unfinished record on every read makes large JSONL records quadratic in size.
    data.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      guard let base = bytes.baseAddress else { return }
      var recordStart = 0
      for index in 0..<bytes.count where bytes[index] == 0x0A {
        buffer.append(base.advanced(by: recordStart), count: index - recordStart)
        if buffer.last == 0x0D { buffer.removeLast() }
        if !buffer.isEmpty { records.append(buffer) }
        buffer = Data()
        recordStart = index + 1
      }
      buffer.append(base.advanced(by: recordStart), count: bytes.count - recordStart)
    }
    return records
  }

  func finish() -> Data? {
    guard !buffer.isEmpty else { return nil }
    defer { buffer.removeAll(keepingCapacity: false) }
    if buffer.last == 0x0D {
      buffer.removeLast()
    }
    return buffer.isEmpty ? nil : buffer
  }
}

import Foundation

/// 严格按 LF 拆分 Pi RPC 的 JSONL 数据，避免把 JSON 字符串中的 Unicode 行分隔符误判成协议边界。
final class JSONLineDecoder {
  private var buffer = Data()

  func append(_ data: Data) -> [Data] {
    buffer.append(data)
    var records: [Data] = []

    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
      var record = buffer[..<newlineIndex]
      if record.last == 0x0D {
        record = record.dropLast()
      }
      if !record.isEmpty {
        records.append(Data(record))
      }
      buffer.removeSubrange(...newlineIndex)
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

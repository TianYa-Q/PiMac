import Foundation

/// 严格按 LF 拆分 Pi RPC 的 JSONL 数据，避免把 JSON 字符串中的 Unicode 行分隔符误判成协议边界。
final class JSONLineDecoder {
  private var buffer = Data()

  func append(_ data: Data) -> [Data] {
    buffer.append(data)
    var records: [Data] = []
    var recordStart = buffer.startIndex

    // Scan the newly completed buffer once. Removing each line from the front would shift the
    // remaining bytes repeatedly and becomes quadratic when one pipe read contains many events.
    for newlineIndex in buffer.indices where buffer[newlineIndex] == 0x0A {
      var recordEnd = newlineIndex
      if recordEnd > recordStart, buffer[buffer.index(before: recordEnd)] == 0x0D {
        recordEnd = buffer.index(before: recordEnd)
      }
      if recordStart < recordEnd {
        records.append(Data(buffer[recordStart..<recordEnd]))
      }
      recordStart = buffer.index(after: newlineIndex)
    }

    if recordStart > buffer.startIndex {
      buffer.removeSubrange(buffer.startIndex..<recordStart)
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

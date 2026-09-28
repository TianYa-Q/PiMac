import Foundation
import Testing

@testable import PiMacApp

struct JSONLineDecoderTests {
  @Test
  func decodesFragmentedRecordsAndPreservesUnicodeSeparators() throws {
    let decoder = JSONLineDecoder()
    let payload = "{\"text\":\"第一段 第二段\"}\n{\"ok\":true}\r\n"
    let bytes = Data(payload.utf8)
    let split = bytes.index(bytes.startIndex, offsetBy: 13)

    #expect(decoder.append(bytes[..<split]).isEmpty)
    let records = decoder.append(bytes[split...])

    #expect(records.count == 2)
    let first = try #require(JSONSerialization.jsonObject(with: records[0]) as? [String: String])
    #expect(first["text"] == "第一段 第二段")
    #expect(decoder.finish() == nil)
  }

  @Test
  func decodesLargeRecordAcrossSmallPipeReads() {
    let decoder = JSONLineDecoder()
    let payload = Data(repeating: 0x78, count: 2 * 1024 * 1024)
    let clock = ContinuousClock()
    let start = clock.now

    for offset in stride(from: 0, to: payload.count, by: 2048) {
      #expect(decoder.append(payload[offset..<min(offset + 2048, payload.count)]).isEmpty)
    }
    let records = decoder.append(Data("\r\nnext\n".utf8))

    #expect(records == [payload, Data("next".utf8)])
    #expect(decoder.finish() == nil)
    #expect(start.duration(to: clock.now) < .seconds(5))
  }
}

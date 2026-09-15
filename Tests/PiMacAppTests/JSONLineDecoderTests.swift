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
}

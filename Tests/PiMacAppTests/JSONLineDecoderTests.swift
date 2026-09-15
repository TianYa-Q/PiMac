import Foundation
import XCTest

@testable import PiMacApp

final class JSONLineDecoderTests: XCTestCase {
  func testDecodesFragmentedRecordsAndPreservesUnicodeSeparators() throws {
    let decoder = JSONLineDecoder()
    let payload = "{\"text\":\"第一段 第二段\"}\n{\"ok\":true}\r\n"
    let bytes = Data(payload.utf8)
    let split = bytes.index(bytes.startIndex, offsetBy: 13)

    XCTAssertTrue(decoder.append(bytes[..<split]).isEmpty)
    let records = decoder.append(bytes[split...])

    XCTAssertEqual(records.count, 2)
    let first = try XCTUnwrap(JSONSerialization.jsonObject(with: records[0]) as? [String: String])
    XCTAssertEqual(first["text"], "第一段 第二段")
    XCTAssertNil(decoder.finish())
  }
}

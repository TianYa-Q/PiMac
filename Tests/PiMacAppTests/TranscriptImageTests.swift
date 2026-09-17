import Foundation
import Testing

@testable import PiMacApp

struct TranscriptImageTests {
  @Test
  func restoresImageBlocksFromUserMessages() throws {
    let imageData = try #require(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      ))
    let message: PiRPCClient.JSON = [
      "role": "user",
      "content": [
        ["type": "text", "text": "查看图片"],
        [
          "type": "image",
          "mimeType": "image/png",
          "data": imageData.base64EncodedString(),
        ],
      ],
    ]

    let entry = try #require(AppModel.chatEntry(from: message))
    let attachment = try #require(entry.attachments.first)

    #expect(entry.text == "查看图片")
    #expect(entry.attachments.count == 1)
    #expect(attachment.mimeType == "image/png")
    #expect(try Data(contentsOf: attachment.url) == imageData)
  }
}

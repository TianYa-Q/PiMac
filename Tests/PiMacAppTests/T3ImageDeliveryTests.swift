import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3ImageDeliveryTests {
  @Test func imageLinkParsingIsExplicitAndBounded() {
    #expect(
      T3ReplyImageLinks.paths(in: "[高清图](images/a.png) ![图](<images/b c.jpg>) [重复](images/a.png)")
        == ["images/a.png", "images/b c.jpg"])
    #expect(
      T3ReplyImageLinks.paths(
        in:
          "[remote](https://example.com/a.png) [bad](javascript:a.png) `![example](a.png)`\n```\n[code](b.png)\n```"
      ).isEmpty)
    #expect(T3ReplyImageLinks.paths(in: "[图](file:///tmp/a%20b.png)") == ["/tmp/a b.png"])
    #expect(
      T3ReplyImageLinks.paths(in: (0..<20).map { "[图](\($0).png)" }.joined(separator: " ")).count
        == 8)
  }

  @Test func directImagesPreserveOfficialIndexOrder() {
    let blocks: [[String: Any]] = [
      ["type": "text", "text": "hello"],
      ["type": "image", "mimeType": "image/png"],
      ["type": "image", "mimeType": "image/svg+xml"],
      ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg"]],
      ["type": "image", "source": ["type": "url", "media_type": "image/png"]],
    ]
    #expect(T3ToolOutputImages.mimeTypes(blocks) == ["image/png", "image/jpeg"])
    #expect(T3ToolOutputImages.mimeTypes(["content": blocks]) == ["image/png", "image/jpeg"])
    #expect(T3ToolOutputImages.mimeTypes(blocks[1]) == ["image/png"])
    #expect(T3ToolOutputImages.mimeTypes(nil).isEmpty)
    #expect(T3ToolOutputImages.mimeTypes(Array(repeating: blocks[1], count: 100)).count == 8)
  }

}

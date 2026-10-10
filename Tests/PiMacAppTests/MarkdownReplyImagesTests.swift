import Foundation
import Testing

@testable import PiMacApp

struct MarkdownReplyImagesTests {
  private func image(_ path: String) -> PromptAttachment {
    PromptAttachment(url: URL(fileURLWithPath: "/tmp/cached.png"), mimeType: "image/png", replyImagePath: path)
  }

  @Test func preservesTextImageOrderAndCaptions() {
    let before = image("before.png")
    let after = image("after.png")
    let parts = MarkdownReplyImages.parts(
      in: "修改前：\n![修改前](before.png)\n修改后：\n[修改后](after.png)",
      attachments: [after, before])
    #expect(parts.count == 4)
    guard parts.count == 4 else { return }
    if case .text(let blocks) = parts[0] { #expect(blocks == [.paragraph("修改前：")]) }
    else { Issue.record("Expected preceding text") }
    if case .image(let attachment, let caption) = parts[1] {
      #expect(attachment.id == before.id)
      #expect(caption == "修改前")
    } else { Issue.record("Expected first image") }
    if case .image(let attachment, _) = parts[3] { #expect(attachment.id == after.id) }
    else { Issue.record("Expected second image") }
  }

  @Test func leavesMissingRemoteAndCodeLinksAlone() {
    let text = "`![example](a.png)` ![missing](missing.png) ![remote](https://example.com/a.png)"
    let parts = MarkdownReplyImages.parts(in: text, attachments: [image("a.png")])
    #expect(parts.count == 1)
    if case .text(let blocks) = parts[0] { #expect(blocks == [.paragraph(text)]) }
    else { Issue.record("Expected unchanged text") }
    #expect(MarkdownReplyImages.renderedPaths(in: "```\n![a](a.png)\n```", attachments: [image("a.png")]).isEmpty)
  }

  @Test func resolvesEncodedPathsWithoutGuessingByIndex() {
    let attachment = image("images/b c.png")
    let parts = MarkdownReplyImages.parts(
      in: "![missing](missing.png) ![图](<images/b%20c.png>) ![重复](images/b%20c.png)",
      attachments: [attachment])
    #expect(parts.count == 3)
    #expect(MarkdownReplyImages.renderedPaths(
      in: "![图](images/b%20c.png)", attachments: [attachment]) == ["images/b c.png"])
  }
}

import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct HTMLRenderTests {
  private let metadata: [String: Any] = [
    "attachmentId": "thread-00000000-0000-4000-8000-000000000001-html", "title": "对比",
    "height": 400, "heights": [[320, 600], [728, 400], [1000, 300]],
  ]

  @Test func readsCompactAndMCPEnvelopesButRejectsFailureAndInvalidReferences() throws {
    let output: [String: Any] = ["htmlRender": metadata]
    let json = String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self)
    let expected = try #require(T3HTMLRender.read(toolName: "html_render", output: output))
    for wrapped: Any in [
      output, json, ["structuredContent": output], ["content": [["type": "text", "text": json]]],
    ] {
      #expect(T3HTMLRender.read(toolName: "mcp__t3-code__html_render", output: wrapped) == expected)
    }
    #expect(T3HTMLRender.read(toolName: "read", output: output) == nil)
    #expect(
      T3HTMLRender.read(
        toolName: "html_render", output: ["isError": true, "structuredContent": output]) == nil)
    #expect(
      T3HTMLRender.read(
        toolName: "html_render",
        output: ["content": [["text": json], ["text": "{\"isError\":true}"]]]) == nil)
    for bad: Any in [
      "file:///tmp/page.html", "../page-html", "https://example.com/page-html", "other-png", "",
    ] {
      var reference = metadata
      reference["attachmentId"] = bad
      #expect(T3HTMLRender.read(toolName: "html_render", output: ["htmlRender": reference]) == nil)
    }
    var reference = metadata
    reference["height"] = true
    #expect(T3HTMLRender.read(toolName: "html_render", output: ["htmlRender": reference]) == nil)
    #expect(
      T3HTMLRender.read(toolName: "html_render", output: String(repeating: "x", count: 20_000))
        == nil)
  }

  @Test func responsiveHeightHonorsExplicitScrollingCap() throws {
    let reference = try #require(
      T3HTMLRender.read(toolName: "html_render", output: ["htmlRender": metadata]))
    #expect(reference.frameHeight(width: 320, contentHeight: nil) == 600)
    #expect(reference.frameHeight(width: 800, contentHeight: nil) == 400)
    #expect(reference.frameHeight(width: 320, contentHeight: 850) == 850)
    var short = metadata
    short["height"] = 200
    let capped = try #require(
      T3HTMLRender.read(toolName: "html_render", output: ["htmlRender": short]))
    #expect(capped.frameHeight(width: 320, contentHeight: 850) == 200)
  }

  @Test func previewFitsConversationViewportWithoutEnlargingShortPages() throws {
    let reference = try #require(
      T3HTMLRender.read(toolName: "html_render", output: ["htmlRender": metadata]))
    #expect(reference.previewHeight(width: 728, contentHeight: 2000, viewportHeight: 400) == 340)
    #expect(reference.previewHeight(width: 728, contentHeight: 2000, viewportHeight: 800) == 680)
    #expect(reference.previewHeight(width: 728, contentHeight: 120, viewportHeight: 400) == 120)
    #expect(reference.previewHeight(width: 728, contentHeight: 2000, viewportHeight: 60) == 51)
    for invalid in [0, -1, Double.nan, Double.infinity] {
      #expect(reference.previewHeight(width: 728, contentHeight: 2000, viewportHeight: invalid) == 510)
    }
  }

  @Test func pageSurvivesProjectionAndStaysOutsideCollapsedActivity() throws {
    let detail = T3V2Presentation.detail([
      "projection": [
        "thread": ["id": "thread"], "runs": [],
        "visibleTurnItems": [
          [
            "item": [
              "id": "page", "type": "dynamic_tool", "toolName": "html_render",
              "status": "completed", "output": ["htmlRender": metadata],
            ]
          ],
          ["item": ["id": "reply", "type": "assistant_message", "text": "已完成"]],
        ],
      ]
    ])
    let model = AppModel()
    model.currentSessionPath = "t3:thread"
    model.apply(detail)
    let turn = try #require(ConversationTurn.group(model.messages).first)
    #expect(turn.htmlRenders.count == 1)
    #expect(turn.finalAssistant?.text == "已完成")
    #expect(turn.activity.allSatisfy { $0.htmlRender == nil })
    #expect(turn.htmlRenders.first?.htmlRender?.title == "对比")
  }

  @Test func wrapperUsesOpaqueSandboxAndEscapesAgentScriptContent() {
    let html = "</script><script>window.evil=true</script>"
    let wrapper = HTMLRenderWebView.document(html: html, dark: true)
    #expect(wrapper.contains("sandbox=\"allow-scripts\""))
    #expect(!wrapper.contains("allow-same-origin"))
    #expect(!wrapper.contains(html))
    #expect(wrapper.contains("e.source!==page.contentWindow"))
    #expect(wrapper.contains("\\u003c"))
    #expect(HTMLRenderWebView.themeJSON(dark: false).contains("--chart-6"))
  }
}

import Testing

@testable import PiMacApp

struct MarkdownMathTests {
  @Test func recognizesDelimitersBeforeMarkdownUnescapesThem() {
    for source in [
      #"\[S=\frac{\sum L_i^2}{D\sum L_i}\]"#, #"位置 \(u\in[0,1]\)"#, "$$x^2$$", "$x_i$",
    ] {
      let blocks = MarkdownParser.parse(source)
      #expect(MarkdownMath.containsMath(blocks))
      #expect(MarkdownMath.bodyHTML(blocks).contains("data-tex="))
    }
  }

  @Test func excludesCodeCurrencyAndUnfinishedStreamingDelimiters() {
    for source in [
      #"`\(x\)`"#, "``$x$``", "```tex\n$x$\n```", "价格 $20 和 $30", #"未完成 \[x^2"#, #"\$x$"#,
    ] {
      #expect(!MarkdownMath.containsMath(MarkdownParser.parse(source)))
    }
    #expect(MarkdownMath.containsMath(MarkdownParser.parse("```math\nx^2\n```")))
  }

  @Test func preservesTexAndEscapesHTMLAtTheBoundary() {
    let html = MarkdownMath.inlineHTML(
      #"**公式** \(x<y\text{宽度}\) `\(code\)` <script>alert(1)</script>"#)
    #expect(html.contains("<strong>公式</strong>"))
    #expect(html.contains(#"data-tex="x&lt;y\text{宽度}""#))
    #expect(html.contains(#"<code>\(code\)</code>"#))
    #expect(!html.contains("<script>"))
    #expect(html.contains("&lt;script&gt;"))
  }

  @Test func preservesInvalidFormulasForRendererFallbackAndBlocksActiveLinks() {
    let html = MarkdownMath.inlineHTML(#"\(\unsupported{x}\) [bad](javascript:alert)"#)
    #expect(html.contains(#">\(\unsupported{x}\)</span>"#))
    #expect(!html.contains("href="))
    let page = MarkdownMath.page(
      blocks: [.paragraph("$x$")], fontSize: 14, dark: true, id: "fixture")
    #expect(page.contains("trust:false"))
    #expect(page.contains("connect-src 'none'"))
    #expect(page.contains("math-error"))
  }
}

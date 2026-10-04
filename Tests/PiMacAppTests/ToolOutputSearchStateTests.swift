import Foundation
import Testing

@testable import PiMacApp

struct ToolOutputSearchStateTests {
  @Test func caseSensitiveSearchRemainsLiteral() {
    let preview = ToolOutputPresentation(text: "😀 ABC abc [a.*] [A.*]")
    let options = ToolOutputSearchOptions(caseSensitive: true)
    #expect(
      preview.search(for: "abc", options: options).ranges == [NSRange(location: 7, length: 3)])
    #expect(preview.search(for: "[a.*]", options: options).ranges.count == 1)
    #expect(preview.search(for: "[a.*]").ranges.count == 2)
  }

  @Test func wholeWordRespectsUnicodeIdentifiersAndCombiningMarks() {
    let preview = ToolOutputPresentation(text: "cat Cat cats _cat cat2 猫cat cat猫 😀cat😀 cat\u{301}")
    let options = ToolOutputSearchOptions(wholeWord: true)
    #expect(preview.search(for: "cat", options: options).ranges.count == 3)
    #expect(
      preview.search(for: "cat", options: .init(caseSensitive: true, wholeWord: true)).ranges.count
        == 2)
    let unicode = ToolOutputPresentation(text: "café caféine café_ (café)")
    #expect(unicode.search(for: "café", options: options).ranges.count == 2)
  }

  @Test func tailPreviewBoundsUnicodeAndNativeLineSeparators() {
    let bytes = ToolOutputPresentation(text: "x中😀a", maximumBytes: 5, fromEnd: true)
    #expect(bytes.text == "😀a")
    #expect(bytes.isTruncated)
    for separator in ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"] {
      let preview = ToolOutputPresentation(
        text: "a\(separator)b\(separator)c", maximumLines: 2, fromEnd: true)
      #expect(preview.text == "b\(separator)c")
      #expect(preview.lineCount == 2)
      #expect(preview.isTruncated)
      #expect(
        !ToolOutputPresentation(text: "b\(separator)c", maximumLines: 2, fromEnd: true).isTruncated)
    }
    #expect(ToolOutputPresentation(text: "", fromEnd: true).text.isEmpty)
  }

  @Test func tailModeRescansOnlyItsBoundedWindowAndTracksStreamingOutput() {
    let prefix = "first cat " + String(repeating: "x", count: ToolOutputPresentation.maximumBytes)
    var state = ToolOutputSearchState(text: prefix + " last cat")
    state.setQuery("cat")
    state.setFromEnd(true, text: prefix + " last cat")
    #expect(state.fromEnd)
    #expect(state.preview.text.hasSuffix("last cat"))
    #expect(!state.preview.text.contains("first cat"))
    #expect(state.matchLabel == "1/1")
    state.updateText(prefix + " last cat cat")
    #expect(state.preview.text.hasSuffix("cat cat"))
    #expect(state.matchLabel == "1/2")
    state.setFromEnd(false, text: prefix + " last cat cat")
    #expect(state.preview.text.hasPrefix("first cat"))
    #expect(state.matchLabel == "1/1")
  }

  @Test func astralUnicodeLettersAreWordCharactersNotSplitSurrogates() {
    let preview = ToolOutputPresentation(text: "𐐀cat cat𐐀 😀cat😀 cat")
    #expect(preview.search(for: "cat", options: .init(wholeWord: true)).ranges.count == 2)
  }

  @Test func matchCapReportsOnlyActualOverflow() {
    for count in [999, 1000, 1001] {
      let preview = ToolOutputPresentation(text: String(repeating: "x ", count: count))
      let matches = preview.search(for: "x", options: .init(wholeWord: true))
      #expect(matches.ranges.count == min(count, 1000))
      #expect(matches.hasMore == (count > 1000))
    }
  }

  @Test func navigationWrapsAndDoesNotChangeResults() {
    var state = ToolOutputSearchState(text: "one ONE one")
    state.setQuery("one")
    let matches = state.matches
    #expect(state.matchLabel == "1/3")
    state.move(by: -1)
    #expect(state.matchLabel == "3/3")
    state.move(by: 1)
    #expect(state.matchLabel == "1/3")
    state.move(by: Int.max)
    state.move(by: Int.min)
    #expect(state.matches == matches)
    #expect(state.selectedRange != nil)
  }

  @Test func queryAndOptionChangesResetNavigation() {
    var state = ToolOutputSearchState(text: "cat Cat cats")
    state.setQuery("cat")
    state.move(by: 2)
    state.setQuery("cat")
    #expect(state.matchIndex == 2, "An unchanged binding must not rescan")
    state.setOptions(.init(wholeWord: true))
    #expect(state.matchLabel == "1/2")
    state.setOptions(.init(caseSensitive: true, wholeWord: true))
    #expect(state.matchLabel == "1/1")
    state.setQuery("missing")
    #expect(state.matchLabel == "无匹配")
    #expect(state.selectedRange == nil)
    state.move(by: -1)
    #expect(state.matchIndex == 0)
    state.setQuery("")
    #expect(state.matchLabel.isEmpty)
  }

  @Test func streamingAppendRetainsNavigationButShrinkClearsInvalidRanges() {
    var state = ToolOutputSearchState(text: "cat cat")
    state.setQuery("cat")
    state.move(by: 1)
    let selected = state.selectedRange
    state.updateText("cat cat cat")
    #expect(state.selectedRange == selected)
    #expect(state.matchLabel == "2/3")
    state.updateText("cat")
    #expect(state.matchLabel == "1/1")
    state.updateText("none")
    #expect(state.selectedRange == nil)
  }

  @Test func changesBeyondPreviewDoNotResetNavigation() {
    let prefix = "cat cat " + String(repeating: "x", count: ToolOutputPresentation.maximumBytes)
    var state = ToolOutputSearchState(text: prefix + "first")
    state.setQuery("cat")
    state.move(by: 1)
    let preview = state.preview
    state.updateText(prefix + "second")
    #expect(state.preview == preview)
    #expect(state.matchLabel == "2/2")
  }
}

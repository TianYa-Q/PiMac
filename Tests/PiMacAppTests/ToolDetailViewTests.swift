import Testing

@testable import PiMacApp

struct ToolDetailViewTests {
  @Test func separatesFilePathAndLineRange() {
    let summary = ReadToolSummary(input: "Sources/PiMacApp/ContentView.swift:40-59")
    #expect(summary.path == "Sources/PiMacApp/ContentView.swift")
    #expect(summary.fileName == "ContentView.swift")
    #expect(summary.rangeLabel == "第 40-59 行")
  }

  @Test func handlesOffsetOnlyAndBarePaths() {
    #expect(ReadToolSummary(input: "README.md:20").rangeLabel == "第 20 行")
    let summary = ReadToolSummary(input: "/tmp/folder with spaces/README.md")
    #expect(summary.fileName == "README.md")
    #expect(summary.range == nil)
  }

  @Test func preservesColonsInsidePaths() {
    let summary = ReadToolSummary(input: "/tmp/name:version.swift:1-10")
    #expect(summary.path == "/tmp/name:version.swift")
    #expect(ReadToolSummary(input: "/tmp/name:version.swift").range == nil)
  }
}

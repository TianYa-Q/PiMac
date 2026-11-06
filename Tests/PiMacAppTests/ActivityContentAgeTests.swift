import Foundation
import Testing

@testable import PiMacApp

struct ActivityContentAgeTests {
  private let now = Date(timeIntervalSince1970: 10_000)

  @Test func minuteThresholdAndFlooring() {
    for (seconds, expected) in [
      (0.0, nil), (60.0, nil), (60.1, "上次新内容：1 分钟前"),
      (119.0, "上次新内容：1 分钟前"), (120.0, "上次新内容：2 分钟前"),
      (-30.0, nil),
    ] {
      let entry = ChatEntry(
        id: "reasoning", kind: .thinking, title: "", text: "",
        timestamp: now.addingTimeInterval(-seconds))
      #expect(ActivityContentAge.label(entries: [entry], at: now) == expected)
    }
  }

  @Test func latestContentWinsIncludingChildTools() {
    let child = ChatEntry(
      id: "child", kind: .tool, title: "", text: "output",
      timestamp: now.addingTimeInterval(-600), contentUpdatedAt: now.addingTimeInterval(-20))
    var parent = ChatEntry(
      id: "parent", kind: .tool, title: "", text: "",
      childToolEntries: [child], timestamp: now.addingTimeInterval(-300))
    #expect(ActivityContentAge.label(entries: [parent], at: now) == nil)
    parent.childToolEntries = []
    #expect(ActivityContentAge.label(entries: [parent], at: now) == "上次新内容：5 分钟前")
    parent.contentUpdatedAt = now.addingTimeInterval(-125)
    #expect(ActivityContentAge.label(entries: [parent], at: now) == "上次新内容：2 分钟前")
  }

  @Test func missingTimeIsNotInvented() {
    #expect(ActivityContentAge.label(entries: [], at: now) == nil)
    let entry = ChatEntry(id: "unknown", kind: .thinking, title: "", text: "", timestamp: nil)
    #expect(ActivityContentAge.label(entries: [entry], at: now) == nil)
  }
}

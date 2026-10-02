import Foundation
import Testing
@testable import PiMacApp

@Test func codemodeOwnsOnlyExplicitlyLinkedTools() throws {
  let parent = ChatEntry(id: "turn:code", kind: .tool, title: "Code Mode", text: "", toolName: "codemode")
  let child = ChatEntry(id: "turn:bash", kind: .tool, title: "bash", text: "failed output", isError: true,
    toolName: "bash", parentToolEntryID: parent.id)
  let independent = ChatEntry(id: "turn:other", kind: .tool, title: "bash", text: "", toolName: "bash")
  let orphan = ChatEntry(id: "turn:orphan", kind: .tool, title: "read", text: "",
    parentToolEntryID: "missing")
  let entries = ChatEntry.groupingToolEntries([child, independent, parent, orphan])
  #expect(entries.count == 3)
  let code = try #require(entries.first { $0.id == parent.id })
  #expect(code.childToolEntries == [child])
  #expect(code.childToolEntries.first?.isError == true)
  #expect(entries.contains { $0.id == independent.id })
  #expect(entries.contains { $0.id == orphan.id })
}

@Test func toolParentLinksAreScopedToTheirTurn() {
  let parent = ChatEntry(id: "old:code", kind: .tool, title: "", text: "", toolName: "codemode")
  let child = ChatEntry(id: "new:bash", kind: .tool, title: "", text: "", parentToolEntryID: "new:code")
  let entries = ChatEntry.groupingToolEntries([parent, child])
  #expect(entries.count == 2)
  #expect(entries[0].childToolEntries.isEmpty)
}

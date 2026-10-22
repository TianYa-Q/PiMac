import Foundation
import Testing

@testable import PiMacApp

struct PiResourceStoreTests {
  private func withStore(_ body: (PiResourceStore, URL) throws -> Void) throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/pi-resource-tests/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try body(
      PiResourceStore(
        agentDirectory: root.appendingPathComponent("agent"), projectURL: project,
        homeDirectory: root.appendingPathComponent("home")),
      root)
  }

  @Test func scopePathsAndLegalEmptyStates() throws {
    try withStore { store, root in
      #expect(try store.skills(for: .global).isEmpty)
      #expect(try store.skills(for: .project).isEmpty)
      let global = try store.instructions(for: .global)
      let project = try store.instructions(for: .project)
      #expect(global.url == root.appendingPathComponent("agent/AGENTS.md"))
      #expect(project.url == root.appendingPathComponent("project/AGENTS.md"))
      let missing = try store.read(global)
      #expect(missing.original == nil)
      try store.save(missing, text: "")
      let empty = try store.read(global)
      #expect(empty.original == Data())
      #expect(empty.text.isEmpty)
      #expect(try store.read(project).original == nil)
      #expect(
        !FileManager.default.fileExists(
          atPath: root.appendingPathComponent("project/.pi/AGENTS.md").path))
    }
  }

  @Test func skillCreationDiscoveryAndSave() throws {
    try withStore { store, _ in
      let draft = try store.newSkill(named: "code-review", scope: .project)
      #expect(!FileManager.default.fileExists(atPath: draft.entry.url.path))
      #expect(draft.text.contains("name: code-review"))
      try store.save(draft, text: draft.text)
      let entries = try store.skills(for: .project)
      #expect(entries.count == 1)
      #expect(entries.first?.title == "code-review")
      let document = try store.read(#require(entries.first))
      try store.save(document, text: document.text + "\n中文指令\n")
      #expect(try store.read(document.entry).text.hasSuffix("中文指令\n"))
      #expect(try store.skills(for: .global).isEmpty)
      #expect(throws: PiResourceStore.StoreError.self) {
        try store.newSkill(named: "code-review", scope: .project)
      }
    }
  }

  @Test func agentsLocationsAreManagedWithoutChangingPiFiles() throws {
    try withStore { store, root in
      let global = try store.newSkill(named: "personal", scope: .global, location: .agents)
      let project = try store.newSkill(named: "poteto-mode", scope: .project, location: .agents)
      try store.save(global, text: global.text)
      try store.save(project, text: project.text)
      #expect(
        global.entry.url == root.appendingPathComponent("home/.agents/skills/personal/SKILL.md"))
      #expect(
        project.entry.url
          == root.appendingPathComponent("project/.agents/skills/poteto-mode/SKILL.md"))
      #expect(try store.skills(for: .global).map(\.title) == ["personal"])
      #expect(try store.skills(for: .project).map(\.title) == ["poteto-mode"])
      #expect(!FileManager.default.fileExists(atPath: store.agentDirectory.path))
    }
  }

  @Test func unsafeNamesAndUnavailableProjectAreRejected() throws {
    try withStore { store, _ in
      for name in [
        "", "../outside", "Upper", "a/b", "-review", "a--b", "a-",
        String(repeating: "a", count: 65),
      ] {
        #expect(throws: PiResourceStore.StoreError.self) {
          try store.newSkill(named: name, scope: .global)
        }
      }
      let globalOnly = PiResourceStore(
        agentDirectory: store.agentDirectory, projectURL: nil, homeDirectory: store.homeDirectory)
      #expect(throws: PiResourceStore.StoreError.self) {
        try globalOnly.instructions(for: .project)
      }
      #expect(throws: PiResourceStore.StoreError.self) {
        try globalOnly.skills(for: .project)
      }
    }
  }

  @Test func externalChangesAndConcurrentCreationAreNotOverwritten() throws {
    try withStore { store, _ in
      let entry = try store.instructions(for: .global)
      let absent = try store.read(entry)
      try store.save(absent, text: "first writer")
      #expect(throws: PiResourceStore.StoreError.self) {
        try store.save(absent, text: "second writer")
      }
      let original = try store.read(entry)
      try Data("external writer".utf8).write(to: entry.url)
      #expect(throws: PiResourceStore.StoreError.self) {
        try store.save(original, text: "my changes")
      }
      #expect(try store.read(entry).text == "external writer")
      #expect(throws: PiResourceStore.StoreError.self) { try store.trash(original) }
      try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
      #expect(throws: PiResourceStore.StoreError.self) {
        try store.save(original, text: "resurrected")
      }
      #expect(try store.read(entry).original == nil)
    }
  }

  @Test func corruptFilesAndWrongDirectoryAreNotEmptyStates() throws {
    try withStore { store, _ in
      let entry = try store.instructions(for: .project)
      try Data([0xff, 0xfe, 0xff]).write(to: entry.url)
      #expect(throws: PiResourceStore.StoreError.self) { try store.read(entry) }
      let skills = try store.skillsDirectory(for: .project)
      try FileManager.default.createDirectory(
        at: skills.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("not a directory".utf8).write(to: skills)
      #expect(throws: (any Error).self) { try store.skills(for: .project) }
    }
  }

  @Test func importPreservesSupportingFilesAndRefusesCollisions() throws {
    try withStore { store, root in
      let source = root.appendingPathComponent("source/review")
      try FileManager.default.createDirectory(
        at: source.appendingPathComponent("references"), withIntermediateDirectories: true)
      try Data("---\nname: review\ndescription: Review code\n---\n".utf8)
        .write(to: source.appendingPathComponent("SKILL.md"))
      try Data("reference content".utf8).write(
        to: source.appendingPathComponent("references/guide.md"))
      try store.importSkill(from: source, scope: .global)
      let entry = try #require(store.skills(for: .global).first)
      #expect(
        try String(
          contentsOf: entry.removalURL.appendingPathComponent("references/guide.md"),
          encoding: .utf8) == "reference content")
      #expect(throws: PiResourceStore.StoreError.self) {
        try store.importSkill(from: source, scope: .global)
      }
      #expect(try store.skills(for: .global).count == 1)
      #expect(
        FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path))
      #expect(throws: PiResourceStore.StoreError.self) {
        try store.importSkill(from: root, scope: .project)
      }
      let recursive = PiResourceStore(
        agentDirectory: source, projectURL: nil, homeDirectory: store.homeDirectory)
      #expect(throws: PiResourceStore.StoreError.self) {
        try recursive.importSkill(from: source, scope: .global)
      }
    }
  }

  @Test func recursiveDiscoveryHandlesStandaloneFilesAndSymlinkLoops() throws {
    try withStore { store, _ in
      let root = try store.skillsDirectory(for: .global)
      let nested = root.appendingPathComponent("group/nested")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
      try Data("skill".utf8).write(to: nested.appendingPathComponent("SKILL.md"))
      try Data("legacy".utf8).write(to: root.appendingPathComponent("legacy.md"))
      try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("loop"), withDestinationURL: root)
      let entries = try store.skills(for: .global)
      #expect(Set(entries.map(\.title)) == ["nested", "legacy"])
    }
  }

  @Test func linkedSkillsAreEditableWithoutReplacingTheLink() throws {
    try withStore { store, root in
      let outside = root.appendingPathComponent("linked-skill")
      let skills = try store.skillsDirectory(for: .global)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
      let target = outside.appendingPathComponent("SKILL.md")
      try Data("before".utf8).write(to: target)
      let link = skills.appendingPathComponent("linked")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
      let entries = try store.skills(for: .global)
      #expect(entries.count == 1)
      let entry = try #require(entries.first)
      try store.save(store.read(entry), text: "after")
      #expect(try String(contentsOf: target, encoding: .utf8) == "after")
      #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.path)
      let instructions = try store.instructions(for: .project)
      try FileManager.default.createSymbolicLink(at: instructions.url, withDestinationURL: target)
      let document = try store.read(instructions)
      try store.save(document, text: "instructions")
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: instructions.url.path)
          == target.path)
      #expect(try String(contentsOf: target, encoding: .utf8) == "instructions")
      let stale = try store.read(instructions)
      let replacement = outside.appendingPathComponent("other.md")
      try Data("instructions".utf8).write(to: replacement)
      try FileManager.default.trashItem(at: instructions.url, resultingItemURL: nil)
      try FileManager.default.createSymbolicLink(
        at: instructions.url, withDestinationURL: replacement)
      #expect(throws: PiResourceStore.StoreError.self) { try store.save(stale, text: "overwrite") }
      #expect(try String(contentsOf: replacement, encoding: .utf8) == "instructions")
    }
  }

  @Test func rootSkillDoesNotMakeTheWholeSkillsDirectoryRemovable() throws {
    try withStore { store, _ in
      let root = try store.skillsDirectory(for: .global)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try Data("root".utf8).write(to: root.appendingPathComponent("SKILL.md"))
      try Data("keep".utf8).write(to: root.appendingPathComponent("reference.txt"))
      let entry = try #require(store.skills(for: .global).first)
      #expect(entry.removalURL == entry.url)
      try store.trash(store.read(entry))
      #expect(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("reference.txt").path))
    }
  }

  @Test func trashMovesWholeSkillWithoutTouchingItsNeighbor() throws {
    try withStore { store, _ in
      let first = try store.newSkill(named: "first", scope: .global)
      let second = try store.newSkill(named: "second", scope: .global)
      try store.save(first, text: first.text)
      try store.save(second, text: second.text)
      try Data("support".utf8).write(
        to: first.entry.removalURL.appendingPathComponent("support.txt"))
      try store.trash(store.read(first.entry))
      #expect(!FileManager.default.fileExists(atPath: first.entry.removalURL.path))
      #expect(try store.skills(for: .global).map(\.title) == ["second"])
    }
  }
}

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PiMacApp

struct TaskLogTests {
  private let root = URL(fileURLWithPath: "/workspace/project", isDirectory: true)

  private func entry(_ name: String, _ input: String) -> ChatEntry {
    ChatEntry(
      id: UUID().uuidString, kind: .tool, title: name, text: "", toolName: name, toolInput: input)
  }

  @Test func followsExplicitReadsAndLocalTailAcrossTurns() throws {
    let older = entry("read", "tmp/older.log:20-30")
    let newer = entry("bash", "$ date; tail -30 'tmp/deploy retry.log'; ps -p 123")
    let source = try #require(TaskLogSource.latest(in: [older, newer], root: root))
    #expect(source.file.path == "/workspace/project/tmp/deploy retry.log")
    var grouped = entry("codemode", "await tools.bash(...)")
    grouped.childToolEntries = [older, newer]
    #expect(TaskLogSource.latest(in: [grouped], root: root) == source)
    #expect(
      TaskLogSource.latest(in: [older], root: root)?.file.path == "/workspace/project/tmp/older.log"
    )
    let absolute = entry("bash", "$ cd /workspace/project/tmp && tail -n 30 deploy.log")
    #expect(
      TaskLogSource.latest(in: [absolute], root: root)?.file.path
        == "/workspace/project/tmp/deploy.log")
    let quoted = entry("bash", "$ tail 'tmp/a&&b.log'")
    #expect(TaskLogSource.latest(in: [quoted], root: root)?.file.lastPathComponent == "a&&b.log")
  }

  @Test func neverGuessesRemotePathsOutputsOrShellExpansions() {
    for input in [
      "$ ssh host 'tail -30 tmp/deploy.log'", "$ echo tail tmp/deploy.log",
      "$ tail $LOG", "$ tail $(pwd)/deploy.log", "$ tail tmp/a.log > tmp/b.log",
      "$ cd $ROOT && tail a.log", "$ tail 'unterminated.log", "$ tail a.log | grep error",
    ] {
      #expect(TaskLogSource.latest(in: [entry("bash", input)], root: root) == nil)
    }
    #expect(TaskLogSource.latest(in: [entry("read", "../other/secret.log")], root: root) == nil)
    #expect(
      TaskLogSource.latest(in: [entry("read", "/workspace/project-other/secret.log")], root: root)
        == nil)
    #expect(TaskLogSource.latest(in: [entry("read", "secrets/token")], root: root) == nil)
    var unrelated = entry("bash", "$ echo done")
    unrelated.text = "tmp/deploy.log"
    #expect(TaskLogSource.latest(in: [unrelated], root: root) == nil)
  }

  @Test func readsRealBackgroundWritesBeforeExitAndRetainsFailureLog() async throws {
    try await withFiles { base in
      let file = base.appendingPathComponent("deployment.log")
      let source = TaskLogSource(root: base, file: file)
      let process = Process()
      let input = Pipe()
      let output = Pipe()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = [
        "-c",
        "printf 'first\\n' > \"$1\"; printf 'ready\\n'; read step; printf 'second 中文\\n' >> \"$1\"; printf 'next\\n'; read step; exit 7",
        "log-writer", file.path,
      ]
      process.standardInput = input
      process.standardOutput = output
      try process.run()
      defer {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
      }
      let ready = try output.fileHandleForReading.read(upToCount: 6)
      #expect(ready == Data("ready\n".utf8))
      let reader = TaskLogReader()
      #expect(try await reader.read(source).text == "first\n")
      #expect(process.isRunning)
      try input.fileHandleForWriting.write(contentsOf: Data("continue\n".utf8))
      #expect(try output.fileHandleForReading.read(upToCount: 5) == Data("next\n".utf8))
      #expect(try await reader.read(source).text == "first\nsecond 中文\n")
      #expect(process.isRunning)
      try input.fileHandleForWriting.write(contentsOf: Data("finish\n".utf8))
      process.waitUntilExit()
      #expect(process.terminationStatus == 7)
      #expect(try await reader.read(source).text.hasSuffix("second 中文\n"))
    }
  }

  @Test func handlesEmptyLargeTruncatedAndRotatedFiles() async throws {
    try await withFiles { base in
      let file = base.appendingPathComponent("deployment.log")
      let source = TaskLogSource(root: base, file: file)
      let reader = TaskLogReader()
      try Data().write(to: file)
      #expect(try await reader.read(source) == TaskLogSnapshot(text: "", isTruncated: false))
      try Data((String(repeating: "旧内容 中文\n", count: 10000) + "latest\n").utf8).write(to: file)
      let large = try await reader.read(source)
      #expect(large.isTruncated)
      #expect(large.text.utf8.count <= TaskLogReader.maximumBytes)
      #expect(large.text.hasSuffix("latest\n"))
      #expect(!large.text.contains("�"))
      try Data("truncated\n".utf8).write(to: file)
      #expect(try await reader.read(source).text == "truncated\n")
      try FileManager.default.moveItem(at: file, to: base.appendingPathComponent("old.log"))
      await #expect(throws: TaskLogReader.Failure.self) { try await reader.read(source) }
      try Data("rotated\n".utf8).write(to: file)
      #expect(try await reader.read(source).text == "rotated\n")
    }
  }

  @Test func rejectsEscapingSymlinksDirectoriesAndMissingFiles() async throws {
    try await withFiles { base in
      let workspace = base.appendingPathComponent("workspace", isDirectory: true)
      try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
      let external = base.appendingPathComponent("outside.log")
      try Data("outside".utf8).write(to: external)
      let link = workspace.appendingPathComponent("escape.log")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
      let reader = TaskLogReader()
      for file in [link, external, workspace, workspace.appendingPathComponent("missing.log")] {
        await #expect(throws: TaskLogReader.Failure.self) {
          try await reader.read(TaskLogSource(root: workspace, file: file))
        }
      }
      let directoryLink = workspace.appendingPathComponent("linked")
      try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: base)
      await #expect(throws: TaskLogReader.Failure.self) {
        try await reader.read(
          TaskLogSource(root: workspace, file: directoryLink.appendingPathComponent("outside.log")))
      }
    }
  }

  @Test @MainActor func panelRefreshesWithoutAnotherAgentReadAndSwitchesSources() async throws {
    try await withFiles { base in
      let first = base.appendingPathComponent("first.log")
      let second = base.appendingPathComponent("second.log")
      try Data("first phase\n".utf8).write(to: first)
      try Data("other task\n".utf8).write(to: second)
      let host = NSHostingView(
        rootView: AnyView(TaskLogPanel(source: TaskLogSource(root: base, file: first)).id(first)))
      host.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
      let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = host
      defer { window.contentView = nil }
      @MainActor func output(_ view: NSView) -> String {
        if let log = view as? ToolOutputScrollView { return log.outputTextView.string }
        return view.subviews.map(output).joined()
      }
      @MainActor func waitFor(_ text: String) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !output(host).contains(text), ContinuousClock.now < deadline {
          host.layoutSubtreeIfNeeded()
          try await Task.sleep(for: .milliseconds(50))
        }
        #expect(output(host).contains(text))
      }
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      #expect(output(host).isEmpty)
      host.rootView = AnyView(
        TaskLogPanel(source: TaskLogSource(root: base, file: first), initiallyExpanded: true)
          .id("expanded-first"))
      try await waitFor("first phase")
      let handle = try FileHandle(forWritingTo: first)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("new phase without a tool call\n".utf8))
      try handle.close()
      try await waitFor("new phase without a tool call")
      host.rootView = AnyView(
        TaskLogPanel(source: TaskLogSource(root: base, file: second), initiallyExpanded: true)
          .id(second))
      try await waitFor("other task")
      #expect(!output(host).contains("first phase"))
    }
  }

  private func withFiles(_ body: (URL) async throws -> Void) async throws {
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/task-live-logs/test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { _ = try? FileManager.default.trashItem(at: base, resultingItemURL: nil) }
    try await body(base)
  }
}

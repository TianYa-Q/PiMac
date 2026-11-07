import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct OutboxIndexTests {
  @Test func indexMatchesFullScanAcrossProjectsStateChangesAndReloads() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/outbox-index-tests/\(UUID().uuidString)")
    let store = MessageOutboxStore(directory: root)
    let projects = [root, root.appendingPathComponent("other")]
    for index in 0..<12 {
      let record = try store.save(
        prompt: #require(
          AppModel.makePrompt("message \(index)", attachments: [], delivery: .steer)),
        messageID: "m\(index)", threadID: "t\(index % 3)", project: projects[index % 2],
        selection: [:], createsThread: true, context: "")
      try store.update(record.id) { $0.state = index < 6 ? .delivered : .unknown }
    }
    func verify(_ store: MessageOutboxStore) {
      for thread in ["t0", "t1", "t2", "absent"] {
        #expect(
          store.firstVisibleRecord(threadID: thread)
            == store.messages.first { $0.threadID == thread && $0.isVisible })
        for project in projects {
          let expected = store.messages.filter {
            $0.threadID == thread && $0.projectPath == project.path && $0.isVisible
          }
          #expect(store.records(threadID: thread, project: project) == expected)
        }
      }
    }
    verify(store)
    try store.update("m6") { $0.state = .dismissed }
    try store.update("m7") { $0.state = .migrated }
    try store.update("m8") { $0.state = .sending }
    verify(store)
    store.reload()
    #expect(store.message("m8")?.state == .unknown)
    verify(store)
    verify(MessageOutboxStore(directory: root))
  }

  @Test func indexedLookupsWithThousandHistoricalRecords() throws {
    let project = URL(fileURLWithPath: "/tmp/outbox-index-performance")
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/outbox-index-tests/\(UUID().uuidString)")
    struct Archive: Encodable {
      let version = 1
      let messages: [OutboxMessage]
    }
    // 一次载入已有历史，避免为准备查询基准执行上千次无关的持久化/索引重建。
    let records = (0..<1000).map { index in
      var record = OutboxMessage(
        id: "m\(index)", threadID: "t\(index)", projectPath: project.path,
        text: "history", rpcText: "history", delivery: .steer, attachments: [], selection: Data(),
        context: String(repeating: "history", count: 3000), createdAt: .now, createsThread: true,
        createCommandID: "create\(index)", dispatchCommandID: "dispatch\(index)")
      record.state = index < 995 ? .delivered : .unknown
      return record
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(Archive(messages: records)).write(
      to: directory.appendingPathComponent("outbox.json"))
    let store = MessageOutboxStore(directory: directory)
    #expect(!store.isReadOnly)
    let clock = ContinuousClock()
    var indexedCount = 0
    let indexedTime = clock.measure {
      for index in 0..<1000 {
        indexedCount += store.records(threadID: "t\(index)", project: project).count
      }
    }
    var scannedCount = 0
    let scanTime = clock.measure {
      for index in 0..<1000 {
        scannedCount +=
          store.messages.filter {
            $0.threadID == "t\(index)" && $0.projectPath == project.path && $0.isVisible
          }.count
      }
    }
    #expect(indexedCount == 5)
    #expect(indexedCount == scannedCount)
    print("Outbox 1000 lookups: indexed=\(indexedTime), fullScan=\(scanTime)")
  }

  @Test func localSidebarMetadataPreservesSteerPriorityAndDraftExclusion() throws {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let model = try #require(workspace.selectedModel)
    let project = URL(fileURLWithPath: "/tmp/outbox-index-sidebar")
    model.projectURL = project
    model.currentSessionPath = "t3:local"
    let store = workspace.deliveries.store
    for (id, delivery) in [("queued", QueuedPromptDelivery.followUp), ("steer", .steer)] {
      _ = try store.save(
        prompt: #require(AppModel.makePrompt(id, attachments: [], delivery: delivery)),
        messageID: id, threadID: "local", project: project, selection: [:], createsThread: true,
        context: "")
    }
    #expect(model.locallySubmittedSession?.title == "steer")
    #expect(workspace.project(forSessionPath: "t3:local")?.url == project)
    try store.update("steer") { $0.state = .draft }
    #expect(model.locallySubmittedSession?.title == "queued")
    try store.update("queued") { $0.state = .delivered }
    #expect(model.locallySubmittedSession == nil)
    try store.update("steer") { $0.state = .dismissed }
    #expect(workspace.project(forSessionPath: "t3:local") == nil)
  }
}

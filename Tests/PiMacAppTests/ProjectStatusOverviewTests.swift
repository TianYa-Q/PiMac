import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ProjectStatusOverviewTests {
  private func model(in project: WorkspaceProject, state: ConnectionState = .connected) -> AppModel
  {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.projectURL = project.url
    model.connectionState = state
    return model
  }

  @Test func aggregatesAllProjectsAndDeduplicatesSharedRuntimes() throws {
    let first = WorkspaceProject(url: URL(fileURLWithPath: "/tmp/status-first"))
    let second = WorkspaceProject(url: URL(fileURLWithPath: "/tmp/status-second"))
    let dormant = WorkspaceProject(url: URL(fileURLWithPath: "/tmp/status-dormant"))
    let desktop = model(in: first)
    desktop.isStreaming = true
    desktop.sessionName = "桌面任务"
    desktop.queuedPrompts = [
      try #require(AppModel.makePrompt("next", attachments: [], delivery: .followUp))
    ]
    let telegram = model(in: second)
    telegram.isStreaming = true
    let ready = model(in: second)
    let summaries = ProjectStatusOverview.summaries(
      projects: [first, second, dormant], models: [desktop, telegram, ready, desktop, telegram],
      selectedProjectPath: second.id,
      remoteQueueCounts: [ObjectIdentifier(desktop): 2, ObjectIdentifier(telegram): 3])
    #expect(summaries.count == 3)
    #expect(summaries[0].running == 1)
    #expect(summaries[0].queued == 3)
    #expect(summaries[1].running == 1)
    #expect(summaries[1].queued == 3)
    #expect(summaries[1].ready == 1)
    #expect(summaries[1].isSelected)
    #expect(summaries[2].running == 0)
    let visible = ProjectStatusOverview.visibleSummaries(summaries)
    #expect(visible.map(\.project.id) == [first.id, second.id])
    let message = ProjectStatusOverview.message(summaries)
    #expect(message.contains("2 执行 · 6 排队"))
    #expect(message.contains("status-first"))
    #expect(message.contains("status-second（当前 Telegram）"))
    #expect(message.contains("status-dormant"))
    #expect(message.contains("桌面任务"))
    #expect(message.contains("未启动或已挂起"))
  }

  @Test func distinguishesStartupConfirmationDeliveryAndFailureWithoutConnecting() {
    let project = WorkspaceProject(url: URL(fileURLWithPath: "/tmp/status-states"))
    let loading = model(in: project)
    loading.isLoadingConfiguration = true
    let connecting = model(in: project, state: .connecting)
    let failed = model(in: project, state: .failed("测试失败"))
    let confirmation = model(in: project)
    let delivery = model(in: project)
    let idle = model(in: project, state: .disconnected)
    let models = [loading, connecting, failed, confirmation, delivery, idle]
    let summaries = ProjectStatusOverview.summaries(
      projects: [project], models: models, selectedProjectPath: nil,
      pendingReplyModels: [ObjectIdentifier(delivery)],
      confirmationModels: [ObjectIdentifier(confirmation)])
    #expect(summaries[0].connecting == 2)
    #expect(summaries[0].failed == 1)
    #expect(summaries[0].confirmations == 1)
    #expect(summaries[0].delivering == 1)
    #expect(summaries[0].ready == 0)
    #expect(ProjectStatusOverview.visibleSummaries(summaries).count == 1)
    #expect(ProjectStatusOverview.message(summaries).contains("测试失败"))
    #expect(models.allSatisfy { !$0.isProcessRunning })
    #expect(idle.connectionState == .disconnected)
  }

  @Test func otherProjectSummaryClarifiesScopeAndDoesNotImplyReplyRouting() {
    var summary = ProjectActivitySummary(
      project: WorkspaceProject(url: URL(fileURLWithPath: "/tmp/PiMac")), isSelected: false)
    summary.running = 1
    summary.queued = 2
    let message = ProjectStatusOverview.message([summary], otherProjectsOnly: true)
    #expect(message.contains("其他活跃或需关注的项目（1/1）"))
    #expect(message.contains("1 项目 · 1 执行 · 2 排队"))
    #expect(message.contains("不含上方项目"))
    #expect(message.contains("仅供查看"))
    #expect(message.contains("切换用 /projects"))
  }

  @Test func paginatesAllProjectsAndKeepsGlobalTotals() {
    let summaries = (1...23).map { index in
      var summary = ProjectActivitySummary(
        project: WorkspaceProject(url: URL(fileURLWithPath: "/tmp/project-\(index)")),
        isSelected: false)
      summary.running = 1
      return summary
    }
    let secondPage = ProjectStatusOverview.message(summaries, page: 2)
    #expect(secondPage.contains("（2/3）"))
    #expect(secondPage.contains("23 执行"))
    #expect(secondPage.contains("project-11"))
    #expect(secondPage.contains("project-20"))
    #expect(!secondPage.contains("project-21"))
    #expect(ProjectStatusOverview.page(Int.max, count: 23) == 3)
    #expect(ProjectStatusOverview.page(-1, count: 23) == 1)
    #expect(ProjectStatusOverview.message([], page: 1).contains("尚无项目"))
  }
}

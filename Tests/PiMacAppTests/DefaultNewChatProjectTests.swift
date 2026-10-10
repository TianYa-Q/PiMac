import Foundation
import Testing
@testable import PiMacApp

@MainActor
struct DefaultNewChatProjectTests {
  @Test func newChatUsesLastSelectedProjectWithoutPrompt() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let first = URL(fileURLWithPath: "/tmp/default-chat-first")
    let last = URL(fileURLWithPath: "/tmp/default-chat-last")
    workspace.newSession(in: first)
    workspace.newSession(in: last)
    workspace.selectedModel?.composerText = "Keep this draft"
    let previous = workspace.selectedModel

    workspace.newSessionInLastProject()

    #expect(workspace.selectedModel?.projectURL == last)
    #expect(workspace.selectedModel !== previous)
    #expect(previous?.composerText == "Keep this draft")
    let newTab = workspace.selectedTabID
    workspace.newSessionInLastProject()
    #expect(workspace.selectedTabID == newTab)
  }

  @Test func newChatPrefersFilteredProjectAndKeepsExistingDraft() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let active = URL(fileURLWithPath: "/tmp/default-chat-active")
    let filtered = WorkspaceProject(url: URL(fileURLWithPath: "/tmp/default-chat-filtered"))
    workspace.newSession(in: active)
    let previous = workspace.selectedModel
    previous?.composerText = "Keep this draft"
    workspace.toggleProjectFilter(filtered)

    workspace.newSessionInLastProject()

    #expect(workspace.selectedModel?.projectURL == filtered.url)
    #expect(previous?.composerText == "Keep this draft")
    #expect(workspace.projectFilterPath == filtered.id)
    let newTab = workspace.selectedTabID
    workspace.newSessionInLastProject()
    #expect(workspace.selectedTabID == newTab)

    workspace.toggleProjectFilter(WorkspaceProject(url: active))
    workspace.newSessionInLastProject()
    #expect(workspace.selectedModel?.projectURL == active)
    workspace.clearProjectFilter()
    workspace.newSessionInLastProject()
    #expect(workspace.selectedModel?.projectURL == active)
  }

  @Test func newChatUsesFilteredProjectWithoutAnActiveProject() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let filtered = WorkspaceProject(url: URL(fileURLWithPath: "/tmp/default-chat-filter-only"))
    workspace.toggleProjectFilter(filtered)

    workspace.newSessionInLastProject()

    #expect(workspace.selectedModel?.projectURL == filtered.url)
    #expect(workspace.projectFilterPath == filtered.id)
  }

  @Test func switchingProjectKeepsUnsentTextAndAttachments() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    workspace.newSession(in: URL(fileURLWithPath: "/tmp/switch-chat-first"))
    let previous = workspace.selectedModel
    previous?.composerText = "Unsent message"
    previous?.isLoadingConfiguration = false
    let attachment = PromptAttachment(url: URL(fileURLWithPath: "/tmp/example.png"), mimeType: "image/png")
    previous?.attachments = [attachment]
    let next = WorkspaceProject(url: URL(fileURLWithPath: "/tmp/switch-chat-next"))

    workspace.switchNewChatProject(to: next)

    #expect(workspace.selectedModel?.projectURL == next.url)
    #expect(workspace.selectedModel?.composerText == "Unsent message")
    #expect(previous?.composerText == "")
    #expect(workspace.selectedModel?.attachments == [attachment])
    #expect(previous?.attachments.isEmpty == true)
  }

  @Test func noKnownProjectDoesNotCreateTab() {
    let workspace = WorkspaceModel(restoreUserState: false)
    defer { workspace.disconnectAll() }
    let id = workspace.selectedTabID
    workspace.newSessionInLastProject()
    #expect(workspace.selectedTabID == id)
    #expect(workspace.tabs.count == 1)
  }
}

import Foundation

/// Private sidecar protocol, not the T3 wire protocol. Targets are runtime IDs returned by
/// snapshot, never caller-supplied file paths. All mutations use the desktop's AppModel.
struct RemoteBridgeRequest: Codable {
  let id: String
  let method: String
  var target: String?
  var text: String?
  var sessionPath: String?
  var projectPath: String?
  var commandId: String?
  var messageId: String?
  var images: [T3RemoteImage]?

  func withoutTransportID() -> Self {
    // Sidecar retries have new private request IDs, but the same command identity.
    return Self(
      id: "", method: method, target: target, text: text,
      sessionPath: sessionPath, projectPath: projectPath,
      commandId: commandId, messageId: messageId, images: images)
  }
}

struct RemoteBridgeFailure: Codable, Equatable {
  let code: String
  let message: String
}

@MainActor
final class RemoteWorkspaceBridge {
  private weak var workspace: WorkspaceModel?
  private let commands: T3WorkspaceCommands
  private let canSend: () -> Bool

  init(
    workspace: WorkspaceModel, commands: T3WorkspaceCommands? = nil,
    canSend: @escaping () -> Bool = { false }
  ) {
    self.workspace = workspace
    self.commands = commands ?? T3WorkspaceCommands()
    self.canSend = canSend
  }

  func handle(_ request: RemoteBridgeRequest, reply: @escaping ([String: Any]) -> Void) {
    func fail(_ code: String, _ message: String) {
      reply(["id": request.id, "error": ["code": code, "message": message]])
    }
    guard !request.id.isEmpty, request.id.utf8.count <= 128 else {
      fail("invalid_request", "Invalid request ID")
      return
    }
    guard let workspace else {
      fail("unavailable", "Workspace closed")
      return
    }
    if request.method == "workspace.catalog" {
      do {
        reply(["id": request.id, "result": try T3WorkspaceReadModel.catalog(workspace)])
      } catch {
        fail("snapshot_too_large", "Read model exceeds the preview budget")
      }
      return
    }
    if request.method == "session.read" {
      do {
        let source = try T3WorkspaceReadModel.readSource(
          workspace, target: request.target, sessionPath: request.sessionPath,
          projectPath: request.projectPath)
        switch source {
        case .loaded(let messages):
          reply(["id": request.id, "result": try T3WorkspaceReadModel.transcript(messages)])
        case .saved(let path, let project):
          Task { @MainActor in
            do {
              let messages = try await Task.detached(priority: .userInitiated) {
                try T3SessionFileReader.read(path: path, project: project)
              }.value
              // The project/catalog/runtime may have changed during disk I/O.
              let current = try T3WorkspaceReadModel.readSource(
                workspace, target: request.target, sessionPath: path, projectPath: project)
              let result: [String: Any]
              if case .loaded(let live) = current {
                result = try T3WorkspaceReadModel.transcript(live)
              } else {
                result = try T3WorkspaceReadModel.transcript(messages)
              }
              reply(["id": request.id, "result": result])
            } catch T3WorkspaceReadModel.ReadError.tooLarge {
              fail("snapshot_too_large", "Read model exceeds the preview budget")
            } catch {
              fail("stale_target", "Refresh the catalog; no session was opened")
            }
          }
        }
      } catch T3WorkspaceReadModel.ReadError.tooLarge {
        fail("snapshot_too_large", "Read model exceeds the preview budget")
      } catch {
        fail("stale_target", "Refresh the catalog; no session was opened")
      }
      return
    }
    if request.method == "session.cancelSend" {
      commands.cancel(request.commandId)
      reply(["id": request.id, "result": ["accepted": true]])
      return
    }
    if request.method == "session.send" {
      guard canSend() else {
        fail(
          "sending_disabled", "T3 connection is stopped; nothing was sent")
        return
      }
      Task { @MainActor in
        do {
          let accepted = try await commands.send(request, workspace: workspace, canSend: canSend)
          if accepted {
            reply(["id": request.id, "result": ["accepted": true]])
          } else {
            fail("submission_failed", "Pi did not accept the message")
          }
        } catch {
          fail("invalid_send", "Message target or attachment is invalid; nothing was sent")
        }
      }
      return
    }
    if request.method == "workspace.snapshot" {
      reply(["id": request.id, "result": Self.snapshot(workspace)])
      return
    }
    guard ["session.prompt", "session.abort"].contains(request.method) else {
      fail("unsupported_method", "Unsupported bridge method")
      return
    }
    guard let target = request.target, let id = UUID(uuidString: target),
      let tab = workspace.tabs.first(where: { $0.id == id })
    else {
      fail("target_not_found", "Refresh the workspace snapshot")
      return
    }
    let model = tab.model
    if request.method == "session.abort" {
      guard model.isBusy || !model.queuedPrompts.isEmpty else {
        reply(["id": request.id, "result": ["accepted": true]])
        return
      }
      model.abort()
      reply(["id": request.id, "result": ["accepted": true]])
      return
    }
    guard let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 256 * 1024
    else {
      fail("invalid_request", "Prompt must contain 1–262144 UTF-8 bytes")
      return
    }
    // Do not implicitly resume, replace or queue a session in this first bridge version.
    // The caller must observe readiness, and rejection must preserve the desktop composer.
    guard model.canSubmitPrompt, !model.isBusy, model.queuedPrompts.isEmpty else {
      fail("session_not_ready", "Session is disconnected, busy or has queued work")
      return
    }
    model.sendRemotePrompt(text) { accepted in
      if accepted {
        reply(["id": request.id, "result": ["accepted": true]])
      } else {
        fail("submission_failed", "Pi did not accept the prompt")
      }
    }
  }

  static func snapshot(_ workspace: WorkspaceModel) -> [String: Any] {
    let projects: [[String: Any]] = workspace.projects.map { project in
      [
        "id": project.id, "name": project.name,
        "sessions": workspace.sessions(in: project.url).map {
          ["path": $0.path, "title": $0.title] as [String: Any]
        },
      ]
    }
    let sessions: [[String: Any]] = workspace.tabs.map { tab in
      let model = tab.model
      return [
        "id": tab.id.uuidString,
        "projectId": model.projectURL?.standardizedFileURL.path ?? "",
        "sessionPath": model.currentSessionPath,
        "title": model.sessionName,
        "ready": model.canSubmitPrompt && !model.isBusy && model.queuedPrompts.isEmpty,
        "busy": model.isBusy,
        "model": model.selectedModelId,
        "thinkingLevel": model.selectedThinkingLevel,
        "messages": model.messages.map { entry -> [String: Any] in
          let kind: String
          switch entry.kind {
          case .user: kind = "user"
          case .assistant: kind = "assistant"
          case .thinking: kind = "thinking"
          case .tool: kind = "tool"
          case .compaction: kind = "compaction"
          case .system: kind = "system"
          }
          return [
            "id": entry.id, "kind": kind, "title": entry.title, "text": entry.text,
            "running": entry.isRunning, "error": entry.isError,
          ]
        },
      ]
    }
    return ["protocolVersion": 1, "projects": projects, "sessions": sessions]
  }
}

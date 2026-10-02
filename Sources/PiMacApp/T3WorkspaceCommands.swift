import CryptoKit
import Foundation
import ImageIO

struct T3RemoteImage: Codable {
  let mimeType: String
  let data: String
}

/// Owns in-flight/replayed sends across sidecar reconnects. Reads never use this path.
@MainActor
final class T3WorkspaceCommands {
  private struct Outcome {
    let signature: Data
    let task: Task<Bool, Never>
  }
  private var outcomes: [String: Outcome] = [:]
  private var cancelled: Set<String> = []

  func cancel(_ commandID: String?) {
    guard let commandID, !commandID.isEmpty, commandID.utf8.count <= 128 else { return }
    if cancelled.count < 256 { cancelled.insert(commandID) }
    outcomes[commandID]?.task.cancel()
  }

  func send(
    _ request: RemoteBridgeRequest, workspace: WorkspaceModel,
    canSend: @escaping () -> Bool = { true }
  ) async throws -> Bool {
    guard canSend() else { throw T3WorkspaceReadModel.ReadError.staleTarget }
    guard let commandID = request.commandId, !commandID.isEmpty, commandID.utf8.count <= 128,
      let messageID = request.messageId, !messageID.isEmpty, messageID.utf8.count <= 128,
      let text = request.text, text.utf8.count <= 256 * 1024,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !(request.images ?? []).isEmpty
    else { throw T3WorkspaceReadModel.ReadError.staleTarget }
    // A catalog and runtime identity must both match before a process may be resumed.
    let source = try T3WorkspaceReadModel.readSource(
      workspace, target: request.target, sessionPath: request.sessionPath,
      projectPath: request.projectPath)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let signature = Data(SHA256.hash(data: try encoder.encode(request.withoutTransportID())))
    if let previous = outcomes[commandID] {
      guard previous.signature == signature else {
        throw T3WorkspaceReadModel.ReadError.staleTarget
      }
      return await previous.task.value
    }
    guard outcomes.count < 256, let path = request.sessionPath, let project = request.projectPath
    else {
      throw T3WorkspaceReadModel.ReadError.tooLarge
    }
    if case .saved(let path, let project) = source {
      _ = try await Task.detached(priority: .userInitiated) {
        try T3SessionFileReader.read(path: path, project: project)
      }.value
      _ = try T3WorkspaceReadModel.readSource(
        workspace, target: request.target, sessionPath: path, projectPath: project)
      // Another send may have reserved this command while I/O was suspended.
      if let previous = outcomes[commandID] {
        guard previous.signature == signature else {
          throw T3WorkspaceReadModel.ReadError.staleTarget
        }
        return await previous.task.value
      }
      guard outcomes.count < 256 else { throw T3WorkspaceReadModel.ReadError.tooLarge }
    }
    guard !cancelled.contains(commandID) else { return false }
    let attachments = try T3ImageAttachments.materialize(request.images ?? [])
    let model = workspace.taskModel(in: URL(fileURLWithPath: project), sessionPath: path)
    workspace.holdRemoteSubmission(model)
    let task = Task { @MainActor in
      defer { workspace.releaseRemoteSubmission(model) }
      let deadline = Date().addingTimeInterval(20)
      while !model.canSubmitPrompt && Date() < deadline {
        guard !Task.isCancelled else {
          T3ImageAttachments.remove(attachments)
          return false
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard !Task.isCancelled, !cancelled.contains(commandID), canSend(),
        workspace.tabs.contains(where: { $0.model === model }),
        model.currentSessionPath == path,
        model.projectURL?.standardizedFileURL.path == project,
        model.canSubmitPrompt, !model.isBusy, model.queuedPrompts.isEmpty,
        (try? T3WorkspaceReadModel.readSource(
          workspace, target: nil, sessionPath: path, projectPath: project)) != nil
      else {
        T3ImageAttachments.remove(attachments)
        return false
      }
      let accepted = await withCheckedContinuation { continuation in
        model.sendRemotePrompt(text, attachments: attachments, messageID: messageID) {
          continuation.resume(returning: $0)
        }
      }
      if accepted { workspace.remoteSessionUpdated(from: model) }
      // Accepted images belong to chat entries; keep them for desktop display.
      return accepted
    }
    outcomes[commandID] = Outcome(signature: signature, task: task)
    return await task.value
  }
}

/// Inline bytes only. Ignore caller filenames and never read attachment/tool URLs.
enum T3ImageAttachments {
  static func materialize(_ images: [T3RemoteImage]) throws -> [PromptAttachment] {
    guard images.count <= 8 else { throw T3WorkspaceReadModel.ReadError.tooLarge }
    var attachments: [PromptAttachment] = []
    var bytes = 0
    do {
      for image in images {
        guard
          let ext = ["image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"][image.mimeType],
          image.data.utf8.count <= 12 * 1024 * 1024,
          let data = Data(base64Encoded: image.data), !data.isEmpty,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let type = CGImageSourceGetType(source) as String?,
          [
            "image/png": "public.png", "image/jpeg": "public.jpeg",
            "image/webp": "org.webmproject.webp",
          ][image.mimeType] == type,
          CGImageSourceGetCount(source) > 0
        else { throw T3WorkspaceReadModel.ReadError.staleTarget }
        bytes += data.count
        guard bytes <= 8 * 1024 * 1024 else { throw T3WorkspaceReadModel.ReadError.tooLarge }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
          "pimac-t3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("image.\(ext)")
        do {
          try data.write(to: url, options: .withoutOverwriting)
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
          try? FileManager.default.removeItem(at: directory)
          throw error
        }
        attachments.append(PromptAttachment(url: url, mimeType: image.mimeType))
      }
      return attachments
    } catch {
      remove(attachments)
      throw error
    }
  }

  static func remove(_ attachments: [PromptAttachment]) {
    for attachment in attachments {
      try? FileManager.default.removeItem(at: attachment.url.deletingLastPathComponent())
    }
  }
}

import AppKit

extension WorkspaceModel {
  func copyThreadReference(threadID: String, title: String) {
    let source = selectedModel
    let changeCount = NSPasteboard.general.changeCount
    Task { @MainActor in
      do {
        let clipboard = try await T3ThreadContext.copy(
          environmentID: server.recoveryEnvironmentID(), threadID: threadID, title: title)
        guard NSPasteboard.general.changeCount == changeCount else {
          source?.statusText = "剪贴板已变化，请重新复制会话引用。"
          return
        }
        try clipboard.write(to: .general)
        source?.statusText = "已复制会话引用"
      } catch {
        source?.statusText = "复制会话引用失败，请检查连接后重试。"
      }
    }
  }

  func openThreadReference(_ reference: T3MessageContext.ThreadReference) {
    let source = selectedModel
    Task { @MainActor in
      do {
        guard try await server.recoveryEnvironmentID() == reference.environmentId else {
          source?.statusText = "此引用来自其他环境，不能在当前 Server 打开。"
          return
        }
        if server.thread(reference.threadId) == nil { try await server.refreshShell() }
        guard let projectID = server.thread(reference.threadId)?["projectId"] as? String,
          let project = server.projects.first(where: { $0["id"] as? String == projectID }),
          let root = project["workspaceRoot"] as? String
        else {
          source?.statusText = "引用会话不存在或当前不可访问。"
          return
        }
        openSession(path: "t3:\(reference.threadId)", in: URL(fileURLWithPath: root))
      } catch {
        source?.statusText = "无法打开引用会话，请检查连接后重试。"
      }
    }
  }
}

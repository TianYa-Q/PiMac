import AppKit
import Combine

/// 侧栏与独立窗口共享一个会话模型和一条流，移动展示位置不会重新开标签或丢失控制权。
@MainActor
final class BrowserPreviewModel: ObservableObject {
  @Published private(set) var tabs: [T3BrowserTab] = []
  @Published private(set) var selection: String?
  @Published private(set) var image: NSImage?
  @Published private(set) var viewport: CGSize = .zero
  @Published private(set) var control = T3BrowserControl.unavailable
  @Published private(set) var failure: String?
  @Published private(set) var listError: String?
  @Published private(set) var notice: String?
  @Published private(set) var visible = false
  @Published private(set) var detached = false
  @Published private(set) var isUpdatingTabs = false
  private var server: T3DesktopClient?
  private var threadID: String?
  private var stream: Task<Void, Never>?
  private var sendTail: Task<Void, Never>?
  private var socket: URLSessionWebSocketTask?
  private var connectionID = UUID()
  private var canvasSize: CGSize = .zero
  private var copyRequestedAt: Date?
  private var windowController: BrowserPreviewWindowController?
  private var tabMutation: Task<Void, Never>?
  private var listVersion = UUID()

  var selectedTab: T3BrowserTab? { tabs.first { $0.id == selection } ?? tabs.first }
  var canManageTabs: Bool { server?.isConnected == true && threadID != nil && !isUpdatingTabs }

  func watch(server: T3DesktopClient, threadID: String?, connected: Bool) async {
    if self.threadID != threadID {
      stop()
      tabs = []
      selection = nil
      visible = false
      listError = nil
    }
    self.server = server
    self.threadID = threadID
    guard connected, let threadID else {
      disconnect()
      if visible { failure = "Server 已断开，等待重新连接…" }
      return
    }
    // Server 重连后仍停留在原来的标签；不乐观恢复“用户正在控制”。
    connect()
    while !Task.isCancelled {
      do {
        let version = listVersion
        let next = try await server.browserPreviewSessions(threadID: threadID)
        try Task.checkCancellation()
        if version == listVersion && !isUpdatingTabs {
          apply(next)
          listError = nil
        }
      } catch {
        if Task.isCancelled { return }
        listError = "浏览器标签读取失败，正在重试…"
      }
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
    }
  }

  func apply(_ next: [T3BrowserTab]) {
    let previousID = selectedTab?.id
    let seen = Set(tabs.compactMap(\.revealID))
    tabs = next
    if !next.contains(where: { $0.id == selection }) { selection = next.first?.id }
    if let revealed = next.first(where: { $0.revealID.map { !seen.contains($0) } == true }) {
      selection = revealed.id
      visible = true
    }
    if selectedTab?.id != previousID { connect() } else if stream == nil { connect() }
    if next.isEmpty { disconnect() }
  }

  func select(_ id: String) {
    guard tabs.contains(where: { $0.id == id }), selectedTab?.id != id else { return }
    selection = id
    connect()
  }

  func setVisible(_ value: Bool) {
    visible = value
    if value {
      connect()
    } else {
      dock()
      disconnect()
    }
  }

  func reconnect() { connect() }

  func updateTabs(closing tabID: String?) {
    guard canManageTabs, let server, let threadID else { return }
    isUpdatingTabs = true
    notice = nil
    let version = UUID()
    listVersion = version
    tabMutation = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.listVersion == version {
          self.isUpdatingTabs = false
          self.listVersion = UUID()
          self.tabMutation = nil
        }
      }
      do {
        try await server.updateBrowserPreviewTab(threadID: threadID, closing: tabID)
        let next = try await server.browserPreviewSessions(threadID: threadID)
        guard !Task.isCancelled, self.threadID == threadID, self.listVersion == version else {
          return
        }
        // 丢弃变更之前发出的旧轮询响应；标签只由 Server 返回的最新列表更新。
        self.apply(next)
        self.listError = nil
      } catch {
        guard !Task.isCancelled, self.threadID == threadID, self.listVersion == version else {
          return
        }
        self.notice = tabID == nil ? "新建标签页失败，请重试" : "关闭标签页失败，请重试"
      }
    }
  }

  func detach() {
    guard selectedTab != nil || windowController != nil else { return }
    visible = true
    detached = true
    if let windowController {
      windowController.showWindow(nil)
      windowController.window?.makeKeyAndOrderFront(nil)
    } else {
      let controller = BrowserPreviewWindowController(model: self)
      windowController = controller
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
    }
  }

  func dock() {
    detached = false
    let controller = windowController
    windowController = nil
    controller?.window?.delegate = nil
    controller?.window?.contentView = nil
    controller?.close()
  }

  func stop() {
    tabMutation?.cancel()
    tabMutation = nil
    isUpdatingTabs = false
    listVersion = UUID()
    visible = false
    dock()
    disconnect()
  }

  func resize(_ size: CGSize) {
    let next = CGSize(
      width: min(3840, max(240, size.width.rounded())),
      height: min(2160, max(240, size.height.rounded())))
    guard next != canvasSize else { return }
    canvasSize = next
    if control.isControlling { send(.resize(next)) }
  }

  func send(_ input: T3BrowserInput) {
    guard input.isAllowed(by: control), let socket else { return }
    if case .key(let action, let key, _, _, let modifiers, _) = input,
      action == "down", modifiers & 6 != 0, ["c", "x"].contains(key.lowercased())
    {
      copyRequestedAt = .now
    }
    let id = connectionID
    let generation = control.generation
    let previous = sendTail
    // 鼠标按下/抬起与键盘消息严格串行；不让多个 Swift Task 的调度顺序改变输入顺序。
    sendTail = Task { [weak self] in
      await previous?.value
      guard let self, self.connectionID == id, self.control.generation == generation,
        input.isAllowed(by: self.control), !Task.isCancelled
      else { return }
      do {
        let data = try JSONSerialization.data(withJSONObject: input.payload)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
      } catch {
        guard self.connectionID == id, !Task.isCancelled else { return }
        self.failure = "浏览器操作发送失败，请重新连接"
        self.disconnect()
      }
    }
  }

  func receive(_ event: T3BrowserEvent) {
    switch event {
    case .frame(let next): image = next
    case .control(let next):
      let wasControlling = control.isControlling
      if !next.isControlling || next.generation != control.generation { copyRequestedAt = nil }
      control = next
      if next.isControlling && !wasControlling && canvasSize != .zero { send(.resize(canvasSize)) }
    case .viewport(let size): viewport = size
    case .clipboard(let text):
      // 只响应用户刚发起的复制/剪切，不允许流里的任意通知静默覆盖本机剪贴板。
      guard control.isControlling, let requested = copyRequestedAt,
        Date.now.timeIntervalSince(requested) < 5
      else { return }
      copyRequestedAt = nil
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    case .popup(let id):
      let version = listVersion
      let sourceConnection = connectionID
      Task { [weak self] in
        guard let self, let server = self.server, let threadID = self.threadID,
          !self.isUpdatingTabs, self.listVersion == version, self.connectionID == sourceConnection
        else { return }
        do {
          let next = try await server.browserPreviewSessions(threadID: threadID)
          guard self.threadID == threadID, self.listVersion == version,
            self.connectionID == sourceConnection, !Task.isCancelled
          else { return }
          self.apply(next)
          self.select(id)
        } catch {
          if self.threadID == threadID, self.listVersion == version,
            self.connectionID == sourceConnection
          {
            self.notice = "新标签读取失败，请稍后从标签列表选择"
          }
        }
      }
    case .notice(let text): notice = text
    case .ignored: break
    }
  }

  private func disconnect() {
    connectionID = UUID()
    stream?.cancel()
    stream = nil
    sendTail?.cancel()
    sendTail = nil
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    control = .unavailable
    copyRequestedAt = nil
  }

  private func connect() {
    disconnect()
    image = nil
    viewport = .zero
    failure = nil
    notice = nil
    guard visible, let tab = selectedTab, let server, server.isConnected, let threadID else {
      return
    }
    let id = connectionID
    stream = Task { [weak self] in
      guard let self else { return }
      do {
        let socket = try await server.browserPreviewSocket(threadID: threadID, tabID: tab.id)
        guard !Task.isCancelled, self.connectionID == id else {
          socket.cancel(with: .normalClosure, reason: nil)
          return
        }
        self.socket = socket
        try await T3BrowserStream.receive(
          socket: socket,
          onFrame: { [weak self] image in
            guard self?.connectionID == id else { return }
            self?.receive(.frame(image))
          },
          onEvent: { [weak self] event in
            guard self?.connectionID == id else { return }
            self?.receive(event)
          })
      } catch {
        guard !Task.isCancelled, self.connectionID == id else { return }
        switch self.socket?.closeCode.rawValue {
        case 4404: self.failure = "浏览器标签已关闭"
        case 4503: self.failure = "服务端浏览器缺少运行依赖，请检查 Server 配置"
        default: self.failure = "浏览器连接已断开，请重新连接"
        }
        self.control = .unavailable
        self.socket?.cancel(with: .normalClosure, reason: nil)
        self.socket = nil
      }
    }
  }
}

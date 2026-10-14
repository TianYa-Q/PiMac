import AppKit
import SwiftUI

/// macOS 14 没有 SwiftUI 滚动阶段 API。意图来自输入事件，位置来自 AppKit；
/// 不用每像素变化的 SwiftUI geometry preference 驱动整个会话页面。
struct ConversationScrollObserver: NSViewRepresentable {
  let onUserScroll: (_ isAtBottom: Bool, _ isUserGesture: Bool) -> Void
  let onBottomVisibilityChange: (Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onBottomVisibilityChange: onBottomVisibilityChange, onUserScroll: onUserScroll)
  }

  func makeNSView(context: Context) -> NSView {
    let view = AttachmentView(frame: .zero)
    view.onAttach = { [weak coordinator = context.coordinator] scroll in
      coordinator?.attach(to: scroll)
    }
    view.reportAttachment()
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.onUserScroll = onUserScroll
    context.coordinator.onBottomVisibilityChange = onBottomVisibilityChange
    (view as? AttachmentView)?.reportAttachment()
  }

  // make/updateNSView 时 SwiftUI 可能尚未把原生视图挂入 NSClipView。
  // 不能只在下一轮队列尝试一次；在真实挂载生命周期中再次建立观察关系。
  private final class AttachmentView: NSView {
    var onAttach: ((NSScrollView?) -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      reportAttachment()
    }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      reportAttachment()
    }

    func reportAttachment() {
      // 生命周期回调可能仍在 SwiftUI 安装视图的事务内；下一轮再发布状态。
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.onAttach?(self.enclosingScrollView)
      }
    }
  }

  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    (view as? AttachmentView)?.onAttach = nil
    coordinator.detach()
  }

  final class Coordinator {
    var onUserScroll: (Bool, Bool) -> Void
    var onBottomVisibilityChange: (Bool) -> Void
    private weak var scrollView: NSScrollView?
    private weak var documentView: NSView?
    private var observers: [NSObjectProtocol] = []
    private var wheelMonitor: Any?
    private var lastOrigin: NSPoint?
    private var lastBottom: Bool?
    private var lastDocumentHeight: CGFloat?
    private var userScrollActive = false
    private var wheelPending = false
    private var reportScheduled = false

    init(
      onBottomVisibilityChange: @escaping (Bool) -> Void,
      onUserScroll: @escaping (Bool, Bool) -> Void
    ) {
      self.onBottomVisibilityChange = onBottomVisibilityChange
      self.onUserScroll = onUserScroll
    }

    deinit {
      observers.forEach(NotificationCenter.default.removeObserver)
      if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
    }

    func detach() {
      observers.forEach(NotificationCenter.default.removeObserver)
      observers.removeAll()
      if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
      wheelMonitor = nil
      scrollView = nil
      documentView = nil
      lastOrigin = nil
      lastBottom = nil
      lastDocumentHeight = nil
      userScrollActive = false
      wheelPending = false
    }

    func attach(to scrollView: NSScrollView?) {
      guard let scrollView,
        self.scrollView !== scrollView || documentView !== scrollView.documentView
      else { return }
      detach()
      self.scrollView = scrollView
      documentView = scrollView.documentView
      scrollView.verticalScrollElasticity = .none
      scrollView.contentView.postsBoundsChangedNotifications = true
      documentView?.postsFrameChangedNotifications = true

      wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
        [weak self, weak scrollView] event in
        guard let self, let scrollView, event.window === scrollView.window,
          scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil)),
          event.scrollingDeltaY != 0
        else { return event }
        self.handleScrollWheel(scrollingDeltaY: event.scrollingDeltaY)
        return event
      }
      observers.append(
        NotificationCenter.default.addObserver(
          forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in self?.scheduleReport() })
      if let documentView {
        observers.append(
          NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: documentView, queue: .main
          ) { [weak self] _ in self?.scheduleReport() })
      }
      observers.append(
        NotificationCenter.default.addObserver(
          forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main
        ) { [weak self, weak scrollView] _ in
          guard let self, let scrollView else { return }
          self.userScrollActive = true
          if !Self.isAtBottom(scrollView) { self.onUserScroll(false, true) }
        })
      observers.append(
        NotificationCenter.default.addObserver(
          forName: NSScrollView.didLiveScrollNotification, object: scrollView, queue: .main
        ) { [weak self] _ in self?.scheduleReport() })
      observers.append(
        NotificationCenter.default.addObserver(
          forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main
        ) { [weak self, weak scrollView] _ in
          guard let self, let scrollView else { return }
          self.reportPosition()
          self.userScrollActive = false
          // 手势结束仍在底部（包括无位移的边界输入）才恢复跟随。
          if Self.isAtBottom(scrollView) { self.onUserScroll(true, false) }
        })
      reportPosition()
    }

    func handleScrollWheel(scrollingDeltaY: CGFloat) {
      guard scrollingDeltaY != 0, let scrollView else { return }
      wheelPending = true
      // 正数是向历史方向的意图，先取消尚未执行的自动定位；但不伪造底部可见性。
      // 实际移动由 bounds 通知确认，不依赖设备是否发送 didLiveScroll。
      onUserScroll(Self.isAtBottom(scrollView) && scrollingDeltaY < 0, true)
      scheduleReport()
    }

    private func scheduleReport() {
      guard !reportScheduled else { return }
      reportScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.reportScheduled = false
        self.reportPosition()
      }
    }

    func reportPosition() {
      guard let scrollView else { return }
      let origin = scrollView.contentView.bounds.origin
      let bottom = Self.isAtBottom(scrollView)
      let height = scrollView.documentView?.bounds.height ?? 0
      let heightChanged = lastDocumentHeight.map { $0 != height } ?? false
      lastDocumentHeight = height
      let moved = lastOrigin.map { $0 != origin } ?? false
      lastOrigin = origin
      // 输入监听发生在 AppKit 移动前。相同原点的底部报告不能立刻撤销上滑意图；
      // 实际位移后才更新模式，布局变化本身不应取消流式输出的跟随。
      if moved && (userScrollActive || wheelPending) {
        onUserScroll(bottom, true)
      } else if moved && bottom {
        onUserScroll(true, false)
      }
      wheelPending = false
      // 同为“不在底部”，文档继续增长也要通知跟随逻辑；HTML/图片定高
      // 不一定伴随新消息。纯像素滚动则不重复发布这个页面级信号。
      if lastBottom != bottom || (heightChanged && !bottom) {
        lastBottom = bottom
        onBottomVisibilityChange(bottom)
      }
    }

    private static func isAtBottom(_ scrollView: NSScrollView) -> Bool {
      guard let documentView = scrollView.documentView else { return true }
      let visible = scrollView.contentView.documentVisibleRect
      let document = documentView.bounds
      let tolerance: CGFloat = 2
      if scrollView.contentView.isFlipped {
        return visible.maxY >= document.maxY - tolerance
      }
      return visible.minY <= document.minY + tolerance
    }
  }
}

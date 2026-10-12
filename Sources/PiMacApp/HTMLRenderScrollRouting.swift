import AppKit

/// 页面没有可滚动内容（或已到边界）时，滚轮必须交回外层会话，不能被 WebKit 吞掉。
struct HTMLRenderScrollState: Equatable {
  var canScrollUp = false
  var canScrollDown = false

  init() {}

  init?(top: Double, height: Double, viewport: Double) {
    guard top.isFinite, height.isFinite, viewport.isFinite, height >= 0, viewport >= 0 else {
      return nil
    }
    canScrollUp = top > 1
    canScrollDown = top + viewport < height - 1
  }

  func routesToConversation(deltaY: CGFloat, deltaX: CGFloat) -> Bool {
    guard deltaY != 0, abs(deltaY) >= abs(deltaX) else { return false }
    return deltaY > 0 ? !canScrollUp : !canScrollDown
  }
}

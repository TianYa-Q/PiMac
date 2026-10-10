import AppKit
import SwiftUI

/// Native magnification keeps the pinch anchor under the fingers and lets the
/// trackpad scroll across the enlarged image without competing SwiftUI gestures.
struct ZoomableImagePreview: NSViewRepresentable {
  let image: NSImage

  func makeNSView(context: Context) -> ImageScrollView {
    let scroll = ImageScrollView()
    scroll.allowsMagnification = true
    scroll.minMagnification = 1
    scroll.maxMagnification = 16
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    let view = NSImageView()
    view.imageScaling = .scaleProportionallyUpOrDown
    view.imageAlignment = .alignCenter
    view.image = image
    scroll.documentView = view
    return scroll
  }

  func updateNSView(_ scroll: ImageScrollView, context: Context) {
    guard let view = scroll.documentView as? NSImageView else { return }
    if view.image !== image { view.image = image }
  }

  final class ImageScrollView: NSScrollView {
    override func layout() {
      super.layout()
      // The document is a fit-to-window canvas at 1×. NSScrollView handles
      // magnification and scrolling of that canvas, including viewport resize.
      let size = contentSize
      if documentView?.frame.size != size {
        documentView?.setFrameSize(size)
      }
    }
  }
}

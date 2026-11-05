import AppKit
import SwiftUI
import Testing

@testable import PiMacApp

@MainActor
struct GoalMenuLayoutTests {
  private final class Probe: ObservableObject {
    @Published var unavailableReason: String?
  }

  /// 读取实际 AppKit 布局；离屏窗口不保证触发 SwiftUI preference 回调。
  private struct FrameProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
      let view = NSView()
      view.identifier = NSUserInterfaceItemIdentifier("goal-menu-frame")
      return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
  }

  private struct Row: View {
    @ObservedObject var probe: Probe
    let width: CGFloat

    var body: some View {
      HStack {
        Label("PiMac", systemImage: "folder")
        Spacer()
        GoalCreationButton(
          unavailableReason: probe.unavailableReason,
          onStart: { _ in false }
        )
        .background(FrameProbe())
      }
      .frame(width: width, height: 32)
    }
  }

  private func frameProbe(in view: NSView) -> NSView? {
    if view.identifier?.rawValue == "goal-menu-frame" { return view }
    for child in view.subviews {
      if let match = frameProbe(in: child) { return match }
    }
    return nil
  }

  @Test(arguments: [CGFloat(520), CGFloat(1400)])
  func goalMenuStaysCompactAndRightAlignedAcrossAvailabilityChanges(width: CGFloat) async throws {
    let probe = Probe()
    let host = NSHostingView(rootView: Row(probe: probe, width: width))
    host.frame = NSRect(x: 0, y: 0, width: width, height: 32)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    var initial: CGRect?
    // 覆盖可用→忙碌→恢复，不以组件能编译或截图生成成功代替宽度检查。
    for reason in [nil, "会话正在执行", nil] as [String?] {
      probe.unavailableReason = reason
      try await Task.sleep(for: .milliseconds(50))
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let measured = try #require(frameProbe(in: host))
      let frame = measured.convert(measured.bounds, to: host)
      #expect(frame.width >= 40 && frame.width <= 120)
      #expect(abs(frame.maxX - width) <= 1)
      #expect(frame.minX >= width - 120)
      if let initial {
        #expect(frame == initial)
      } else {
        initial = frame
      }
    }
  }
}

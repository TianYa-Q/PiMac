import AppKit
import SwiftUI
import Testing

@testable import PiMacApp

@MainActor
struct GoalExpansionTests {
  private final class Probe: ObservableObject {
    @Published var expanded = false
  }

  private struct FrameProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ view: NSView, context: Context) {}
  }

  private struct Page: View {
    @ObservedObject var probe: Probe
    let measured: NSView

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        Text("当前目标 · 目标受阻").fontWeight(.semibold)
        GoalObjectiveText(
          objective: (1...12).map { "第\($0)项：参考现有软件的优化逻辑，完整迁移并验证结果。" }.joined(separator: "\n"),
          expanded: probe.expanded
        ).background(FrameProbe(view: measured))
        Button(probe.expanded ? "收起正文" : "展开正文") { probe.expanded.toggle() }
          .buttonStyle(.plain)
          .foregroundStyle(Color.accentColor)
      }
      .font(.system(size: 12))
      .padding(12)
      .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
      .padding(12)
      .frame(width: 720, height: 170, alignment: .top)
      .frame(height: 400, alignment: .top)
      .background(Color(nsColor: .windowBackgroundColor))
      .preferredColorScheme(.light)
    }
  }

  @Test func selectableObjectiveRelayoutsWhenExpandedInConstrainedComposer() async throws {
    let probe = Probe()
    let measured = NSView()
    let host = NSHostingView(rootView: Page(probe: probe, measured: measured))
    host.frame = NSRect(x: 0, y: 0, width: 720, height: 400)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    let collapsedHeight = measured.frame.height
    #expect(collapsedHeight > 30 && collapsedHeight < 60)
    probe.expanded = true
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    #expect(measured.frame.height - collapsedHeight > 100)
    if let output = ProcessInfo.processInfo.environment["PIMAC_GOAL_CAPTURE"] {
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try #require(bitmap.representation(using: .png, properties: [:]))
        .write(to: URL(fileURLWithPath: output))
    }
    probe.expanded = false
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    #expect(abs(measured.frame.height - collapsedHeight) < 1)
  }
}

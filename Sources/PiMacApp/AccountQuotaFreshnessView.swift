import SwiftUI

/// A small independent timeline avoids redrawing the entire quota card each minute.
struct AccountQuotaFreshnessView: View {
  let capturedAt: Date?
  let maxAge: TimeInterval

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let freshness = AccountUsageSnapshot.freshness(
        capturedAt: capturedAt, now: context.date, maxAge: maxAge)
      if AccountUsageSnapshot.shouldShowFreshness(capturedAt: capturedAt, now: context.date) {
        HStack(spacing: 3) {
          Image(systemName: freshness == .fresh ? "clock" : "exclamationmark.clock")
          if freshness == .clockSkew {
            Text("采样时间异常，请刷新")
          } else if let capturedAt {
            Text("采样")
            Text(capturedAt, style: .relative)
            if freshness == .stale { Text("· 已过期") }
          } else {
            Text("采样时间未知")
          }
        }
        .font(.caption2)
        .foregroundStyle(freshness == .stale || freshness == .clockSkew ? Color.orange : .secondary)
        .help(
          capturedAt.map { "额度采样：\($0.formatted(date: .abbreviated, time: .standard))；不是状态发布时间" }
            ?? "旧版扩展未提供采样时间，不能判断额度是否新鲜"
        )
        .accessibilityElement(children: .combine)
      }
    }
  }
}

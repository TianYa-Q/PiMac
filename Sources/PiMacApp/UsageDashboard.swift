import Charts
import Foundation
import SwiftUI

struct UsageDay: Identifiable, Hashable, Sendable {
  let date: Date
  var tokens: Int
  var cost: Double

  var id: Date { date }
}

struct ModelUsage: Identifiable, Hashable, Sendable {
  let name: String
  var tokens: Int
  var cost: Double
  var requests: Int

  var id: String { name }
}

struct ProjectUsage: Identifiable, Hashable, Sendable {
  let path: String
  var tokens: Int
  var cost: Double
  var sessions: Int

  var id: String { path }
  var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct UsageSnapshot: Sendable {
  var totalTokens = 0
  var inputTokens = 0
  var outputTokens = 0
  var cacheReadTokens = 0
  var cacheWriteTokens = 0
  var cost = 0.0
  var requests = 0
  var sessions = 0
  var days: [UsageDay] = []
  var models: [ModelUsage] = []
  var projects: [ProjectUsage] = []

  var cacheHitPercent: Double? {
    let promptTokens = Double(inputTokens) + Double(cacheReadTokens) + Double(cacheWriteTokens)
    guard promptTokens > 0 else { return nil }
    return Double(cacheReadTokens) / promptTokens * 100
  }
}

enum UsagePeriod: String, CaseIterable, Identifiable {
  case week
  case month
  case all

  var id: String { rawValue }

  var label: String {
    switch self {
    case .week: "7 天"
    case .month: "30 天"
    case .all: "全部"
    }
  }

  var startDate: Date? {
    let calendar = Calendar.current
    switch self {
    case .week: return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: .now))
    case .month:
      return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: .now))
    case .all: return nil
    }
  }
}

@MainActor
private final class UsageDashboardModel: ObservableObject {
  @Published var period: UsagePeriod = .month
  @Published var snapshot = UsageSnapshot()
  @Published var isLoading = false
  private var generation = UUID()

  func reload() {
    let nextGeneration = UUID()
    generation = nextGeneration
    let period = period
    isLoading = true
    Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        UsageScanner.scan(period: period)
      }.value
      guard let self, self.generation == nextGeneration else { return }
      self.snapshot = result
      self.isLoading = false
    }
  }
}

struct UsageDashboardView: View {
  @StateObject private var model = UsageDashboardModel()
  @State private var exportError: String?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if model.isLoading, model.snapshot.requests == 0 {
        Spacer()
        ProgressView("正在统计会话记录…")
        Spacer()
      } else if model.snapshot.requests == 0 {
        ContentUnavailableView(
          "暂无用量记录",
          systemImage: "chart.bar.xaxis",
          description: Text("Pi 产生模型调用后，这里会显示 Token、费用和趋势。")
        )
      } else {
        dashboard
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .task { model.reload() }
    .onChange(of: model.period) { model.reload() }
    .alert(
      "导出失败",
      isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
    ) {
      Button("确定", role: .cancel) { exportError = nil }
    } message: {
      Text(exportError ?? "")
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("用量看板").font(.title2.bold())
        Text("汇总 ~/.pi/agent/sessions 中的本地会话记录")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Picker("统计范围", selection: $model.period) {
        ForEach(UsagePeriod.allCases) { period in Text(period.label).tag(period) }
      }
      .pickerStyle(.segmented)
      .frame(width: 220)
      if model.isLoading { ProgressView().controlSize(.small).accessibilityLabel("正在统计用量") }
      Button {
        exportCSV()
      } label: {
        Label("导出", systemImage: "square.and.arrow.up")
      }
      .disabled(model.isLoading || model.snapshot.requests == 0)
      .help("导出当前范围的模型和项目汇总 CSV，不包含消息正文")
      Button(action: model.reload) {
        Image(systemName: "arrow.clockwise")
      }
      .disabled(model.isLoading)
      .help("重新统计")
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
  }

  private func exportCSV() {
    let snapshot = model.snapshot
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "pimac-usage-\(model.period.rawValue).csv"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do { try UsageCSV.export(snapshot).write(to: url, atomically: true, encoding: .utf8) } catch {
        exportError = error.localizedDescription
      }
    }
  }

  private var dashboard: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12
        ) {
          metricCard(
            "总 Token", value: compact(model.snapshot.totalTokens), icon: "number", tint: .blue)
          metricCard(
            "估算费用", value: currency(model.snapshot.cost), icon: "dollarsign.circle", tint: .green)
          metricCard(
            "用量记录", value: model.snapshot.requests.formatted(), icon: "sparkles", tint: .purple)
          metricCard(
            "活跃会话", value: model.snapshot.sessions.formatted(),
            icon: "bubble.left.and.bubble.right", tint: .orange)
        }

        HStack(alignment: .top, spacing: 14) {
          chartCard
          tokenCompositionCard
            .frame(width: 250)
        }

        HStack(alignment: .top, spacing: 14) {
          modelBreakdown
          projectBreakdown
        }
      }
      .padding(24)
    }
  }

  private func metricCard(_ title: String, value: String, icon: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: icon)
          .foregroundStyle(tint)
          .frame(width: 28, height: 28)
          .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        Spacer()
        Text(title).font(.caption).foregroundStyle(.secondary)
      }
      Text(value)
        .font(.system(.title2, design: .rounded, weight: .semibold))
        .monospacedDigit()
    }
    .padding(15)
    .background(.background, in: RoundedRectangle(cornerRadius: 13))
    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.35)))
  }

  private var chartCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Token 趋势").font(.headline)
      Chart(model.snapshot.days) { day in
        AreaMark(
          x: .value("日期", day.date, unit: .day),
          y: .value("Token", day.tokens)
        )
        .foregroundStyle(
          LinearGradient(
            colors: [.blue.opacity(0.35), .blue.opacity(0.03)], startPoint: .top, endPoint: .bottom)
        )
        LineMark(
          x: .value("日期", day.date, unit: .day),
          y: .value("Token", day.tokens)
        )
        .foregroundStyle(.blue)
        .lineStyle(StrokeStyle(lineWidth: 2))
      }
      .chartYAxis { AxisMarks(position: .leading) }
      .frame(height: 210)
    }
    .padding(16)
    .frame(maxWidth: .infinity)
    .background(.background, in: RoundedRectangle(cornerRadius: 13))
    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.35)))
  }

  private var tokenCompositionCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Token 构成").font(.headline)
      usageRow("输入", value: model.snapshot.inputTokens, color: .blue)
      usageRow("输出", value: model.snapshot.outputTokens, color: .purple)
      usageRow("缓存读取", value: model.snapshot.cacheReadTokens, color: .green)
      usageRow("缓存写入", value: model.snapshot.cacheWriteTokens, color: .orange)
      Divider()
      HStack {
        Text("缓存命中率").foregroundStyle(.secondary)
        Spacer()
        Text(model.snapshot.cacheHitPercent.map { "\(Int($0.rounded()))%" } ?? "--")
          .monospacedDigit().fontWeight(.semibold)
      }
      .font(.caption)
    }
    .padding(16)
    .background(.background, in: RoundedRectangle(cornerRadius: 13))
    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.35)))
  }

  private func usageRow(_ title: String, value: Int, color: Color) -> some View {
    VStack(spacing: 5) {
      HStack {
        Label(title, systemImage: "circle.fill").foregroundStyle(color)
        Spacer()
        Text(compact(value)).monospacedDigit().foregroundStyle(.secondary)
      }
      .font(.caption)
      ProgressView(value: Double(value), total: Double(max(model.snapshot.totalTokens, 1)))
        .tint(color)
    }
  }

  private var modelBreakdown: some View {
    breakdownCard(title: "模型与工具用量", icon: "cpu") {
      ForEach(model.snapshot.models.prefix(6)) { item in
        breakdownRow(
          title: item.name,
          subtitle: "\(item.requests) 次 · \(currency(item.cost))",
          value: compact(item.tokens),
          fraction: Double(item.tokens) / Double(max(model.snapshot.totalTokens, 1)),
          color: .purple
        )
      }
    }
  }

  private var projectBreakdown: some View {
    breakdownCard(title: "项目用量", icon: "folder") {
      ForEach(model.snapshot.projects.prefix(6)) { item in
        breakdownRow(
          title: item.name,
          subtitle: "\(item.sessions) 个会话 · \(currency(item.cost))",
          value: compact(item.tokens),
          fraction: Double(item.tokens) / Double(max(model.snapshot.totalTokens, 1)),
          color: .blue
        )
        .help(item.path)
      }
    }
  }

  private func breakdownCard<Content: View>(
    title: String, icon: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 13) {
      Label(title, systemImage: icon).font(.headline)
      content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 13))
    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.35)))
  }

  private func breakdownRow(
    title: String, subtitle: String, value: String, fraction: Double, color: Color
  ) -> some View {
    VStack(spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.callout).lineLimit(1)
          Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
      GeometryReader { geometry in
        Capsule().fill(.quaternary)
          .overlay(alignment: .leading) {
            Capsule().fill(color.opacity(0.75))
              .frame(width: geometry.size.width * max(0, min(fraction, 1)))
          }
      }
      .frame(height: 4)
    }
  }

  private func compact(_ value: Int) -> String {
    if value >= 1_000_000 {
      return String(format: "%.2fM", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
      return String(format: "%.1fK", Double(value) / 1_000)
    }
    return value.formatted()
  }

  private func currency(_ value: Double) -> String {
    value.formatted(.currency(code: "USD"))
  }
}

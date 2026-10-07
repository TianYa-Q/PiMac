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
  var coverageWarnings: [String] = []

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
final class UsageDashboardModel: ObservableObject {
  @Published var period: UsagePeriod = .month
  @Published var snapshot = UsageSnapshot()
  @Published var isLoading = false
  @Published var error: String?
  @Published var startedAt = Date.now
  private var generation = UUID()
  private var loadTask: Task<Void, Never>?
  private let load: (UsagePeriod) async throws -> UsageSnapshot

  init(load: @escaping (UsagePeriod) async throws -> UsageSnapshot) { self.load = load }

  func cancel() {
    loadTask?.cancel()
    loadTask = nil
    generation = UUID()
    isLoading = false
    error = "请求已取消，可点击刷新重新获取。"
  }

  func reload() {
    loadTask?.cancel()
    let nextGeneration = UUID()
    generation = nextGeneration
    let period = period
    let load = load
    snapshot = UsageSnapshot()
    error = nil
    startedAt = .now
    isLoading = true
    loadTask = Task { [weak self] in
      do {
        let result = try await load(period)
        guard let self, self.generation == nextGeneration, !Task.isCancelled else { return }
        self.snapshot = result
      } catch {
        guard let self, self.generation == nextGeneration, !Task.isCancelled else { return }
        self.error = "无法获取 T3 Server 用量汇总，请确认连接后重试。"
      }
      guard let self, self.generation == nextGeneration else { return }
      self.isLoading = false
      self.loadTask = nil
    }
  }
}

struct UsageDashboardView: View {
  @StateObject private var model: UsageDashboardModel
  @State private var exportError: String?

  init(server: T3DesktopClient) {
    _model = StateObject(wrappedValue: UsageDashboardModel { period in
      try await server.usageSummary(period: period)
    })
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if model.isLoading, model.snapshot.requests == 0 {
        Spacer()
        VStack(spacing: 12) {
          ProgressView("正在获取 T3 Server 用量汇总…")
          scanStatus
          Text("统计由 Server 执行；首次读取历史记录可能较慢。")
            .font(.caption).foregroundStyle(.secondary)
          Button("取消", action: model.cancel)
        }
        .frame(width: 380)
        Spacer()
      } else if let error = model.error {
        ContentUnavailableView {
          Label("用量读取未完成", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error)
        } actions: {
          Button("重试", action: model.reload)
        }
      } else if model.snapshot.requests == 0 {
        ContentUnavailableView(
          "暂无用量记录",
          systemImage: "chart.bar.xaxis",
          description: Text(model.snapshot.coverageWarnings.isEmpty
            ? "当前范围内没有 Server 用量记录。"
            : model.snapshot.coverageWarnings.joined(separator: "\n"))
        )
      } else {
        dashboard
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .task { model.reload() }
    .onChange(of: model.period) { model.reload() }
    .onDisappear { model.cancel() }
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
        Text("由 T3 Server 提供用量汇总 · 费用为 API 等效估算，非订阅账单")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Picker("统计范围", selection: $model.period) {
        ForEach(UsagePeriod.allCases) { period in Text(period.label).tag(period) }
      }
      .pickerStyle(.segmented)
      .frame(width: 220)
      if model.isLoading {
        scanStatus.frame(width: 170)
        Button("取消", action: model.cancel)
      }
      Button {
        exportCSV()
      } label: {
        Label("导出", systemImage: "square.and.arrow.up")
      }
      .disabled(model.isLoading || model.snapshot.requests == 0)
      .help("导出 Server 返回的当前范围模型汇总 CSV，不包含消息正文")
      Button(action: model.reload) {
        Image(systemName: "arrow.clockwise")
      }
      .disabled(model.isLoading)
      .help("重新统计")
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
  }

  private var scanStatus: some View {
    VStack(spacing: 5) {
      Text("等待 Server 返回…")
      TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
        Text("已耗时 \(max(0, Int(context.date.timeIntervalSince(model.startedAt)))) 秒")
      }
    }
    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
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
        ForEach(model.snapshot.coverageWarnings, id: \.self) { warning in
          Label(warning, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
        }
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
            "会话（按来源）", value: model.snapshot.sessions.formatted(),
            icon: "bubble.left.and.bubble.right", tint: .orange)
        }

        HStack(alignment: .top, spacing: 14) {
          chartCard
          tokenCompositionCard
            .frame(width: 250)
        }

        modelBreakdown
        Text("会话数为各来源的独立会话数之和，同一会话跨来源可能重复；Server 暂未提供项目维度。")
          .font(.caption).foregroundStyle(.secondary)
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
    breakdownCard(title: "模型用量", icon: "cpu") {
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

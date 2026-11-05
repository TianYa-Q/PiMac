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

  func day(at date: Date?, calendar: Calendar) -> UsageDay? {
    guard let date else { return nil }
    // 使用与图表日分桶相同的日历；不把历史缺失日期吸附到相邻有用量的日期。
    return days.first { calendar.isDate($0.date, inSameDayAs: date) }
  }

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
  private var snapshotPeriod: UsagePeriod = .month
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
    // 同范围刷新保留已显示的数据；切换范围则清空，避免把旧范围误标为新范围。
    if snapshotPeriod != period { snapshot = UsageSnapshot() }
    error = nil
    startedAt = .now
    isLoading = true
    loadTask = Task { [weak self] in
      do {
        let result = try await load(period)
        guard let self, self.generation == nextGeneration, !Task.isCancelled else { return }
        self.snapshot = result
        self.snapshotPeriod = period
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
  @State private var hoveredDate: Date?
  private let automaticallyLoads: Bool

  init(model: UsageDashboardModel, automaticallyLoads: Bool, hoveredDate: Date? = nil) {
    _model = StateObject(wrappedValue: model)
    _hoveredDate = State(initialValue: hoveredDate)
    self.automaticallyLoads = automaticallyLoads
  }

  init(server: T3DesktopClient) {
    automaticallyLoads = true
    _model = StateObject(
      wrappedValue: UsageDashboardModel { period in
        try await server.usageSummary(period: period)
      })
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let error = model.error, model.snapshot.requests == 0 {
        ContentUnavailableView {
          Label("用量读取未完成", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error)
        } actions: {
          Button("重试", action: model.reload)
        }
      } else if model.snapshot.requests == 0 && !model.isLoading {
        ContentUnavailableView(
          "暂无用量记录",
          systemImage: "chart.bar.xaxis",
          description: Text(
            model.snapshot.coverageWarnings.isEmpty
              ? "当前范围内没有 Server 用量记录。"
              : model.snapshot.coverageWarnings.joined(separator: "\n"))
        )
      } else {
        dashboard
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .task { if automaticallyLoads { model.reload() } }
    .onChange(of: model.period) {
      hoveredDate = nil
      model.reload()
    }
    .onChange(of: model.isLoading) {
      if model.isLoading { hoveredDate = nil }
    }
    .onDisappear { model.cancel() }
  }

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("用量看板").font(.title2.bold())
        Text("API 等效费用估算，非订阅账单 · 数据来自 T3 Server")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Picker("统计范围", selection: $model.period) {
        ForEach(UsagePeriod.allCases) { period in Text(period.label).tag(period) }
      }
      .pickerStyle(.segmented)
      .frame(width: 220)
      Button(action: model.isLoading ? model.cancel : model.reload) {
        ZStack {
          Image(systemName: "arrow.clockwise").opacity(model.isLoading ? 0 : 1)
          ProgressView().controlSize(.small).opacity(model.isLoading ? 1 : 0)
        }
        .frame(width: 16, height: 16)
      }
      .accessibilityLabel(model.isLoading ? "取消更新" : "刷新用量")
      .help(model.isLoading ? "正在获取用量，点击取消" : "重新统计")
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
  }

  private var dashboard: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let error = model.error {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.orange)
        }
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

        HStack(alignment: .top, spacing: 16) {
          chartCard
          tokenCompositionCard
            .frame(width: 250)
        }

        modelBreakdown
        Text("会话数为各来源的独立会话数之和，同一会话跨来源可能重复；Server 暂未提供项目维度。")
          .font(.caption).foregroundStyle(.secondary)
      }
      .padding(24)
      .redacted(reason: model.isLoading && model.snapshot.requests == 0 ? .placeholder : [])
      .overlay(alignment: .top) {
        if model.isLoading && model.snapshot.requests == 0 {
          Text("正在获取用量汇总，首次读取可能较慢…")
            .font(.callout).padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 120)
        }
      }
    }
  }

  private func metricCard(_ title: String, value: String, icon: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Label {
        Text(title).foregroundStyle(.secondary)
      } icon: {
        Image(systemName: icon).foregroundStyle(tint)
      }
      .font(.callout)
      Text(value)
        .font(.system(size: 28, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(18)
    .background(.background, in: RoundedRectangle(cornerRadius: 13))
    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.35)))
  }

  private var chartCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Token 趋势").font(.headline)
        Spacer()
        Text("每日用量 · Token").font(.caption).foregroundStyle(.secondary)
      }
      Chart {
        ForEach(model.snapshot.days) { day in
          AreaMark(
            x: .value("日期", day.date, unit: .day),
            y: .value("Token", day.tokens)
          )
          .foregroundStyle(
            LinearGradient(
              colors: [.blue.opacity(0.20), .blue.opacity(0.01)], startPoint: .top,
              endPoint: .bottom)
          )
          LineMark(
            x: .value("日期", day.date, unit: .day),
            y: .value("Token", day.tokens)
          )
          .foregroundStyle(.blue)
          .lineStyle(StrokeStyle(lineWidth: 2))
        }
        if let day = model.snapshot.day(at: hoveredDate, calendar: .current) {
          PointMark(
            x: .value("日期", day.date, unit: .day),
            y: .value("Token", day.tokens)
          )
          .foregroundStyle(.blue)
          .symbolSize(45)
          RuleMark(x: .value("日期", day.date, unit: .day))
            .foregroundStyle(.secondary.opacity(0.5))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .annotation(
              position: .top, spacing: 6,
              overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))
            ) {
              VStack(alignment: .leading, spacing: 8) {
                Text(day.date.formatted(.dateTime.year().month().day()))
                  .fontWeight(.semibold)
                HStack {
                  Text("Token").foregroundStyle(.secondary)
                  Spacer()
                  Text(compact(day.tokens)).monospacedDigit()
                }
                HStack {
                  Text("估算费用").foregroundStyle(.secondary)
                  Spacer()
                  Text(currency(day.cost)).monospacedDigit()
                }
              }
              .font(.caption)
              .padding(12)
              .frame(width: 200)
              .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
              .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4)))
              .allowsHitTesting(false)
            }
        }
      }
      .chartOverlay { proxy in
        GeometryReader { geometry in
          Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
              guard case .active(let location) = phase,
                let anchor = proxy.plotFrame,
                geometry[anchor].contains(location), !model.isLoading
              else {
                hoveredDate = nil
                return
              }
              hoveredDate = proxy.value(atX: location.x - geometry[anchor].minX, as: Date.self)
            }
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
          AxisValueLabel {
            if let tokens = value.as(Int.self) {
              // 固定缩写语言，与总量和模型列表的 K / M / B 保持一致，避免本地化成万 / 亿。
              Text(
                tokens.formatted(.number.notation(.compactName).locale(Locale(identifier: "en_US")))
              )
            }
          }
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 5)) { _ in
          AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
        }
      }
      .frame(maxHeight: .infinity)
    }
    .padding(18)
    .frame(maxWidth: .infinity)
    .frame(height: 260)
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
      Spacer(minLength: 0)
      Divider()
      HStack {
        Text("缓存命中率").foregroundStyle(.secondary)
        Spacer()
        Text(model.snapshot.cacheHitPercent.map { "\(Int($0.rounded()))%" } ?? "--")
          .monospacedDigit().fontWeight(.semibold)
      }
      .font(.caption)
    }
    .padding(18)
    .frame(height: 260)
    .background(.background, in: RoundedRectangle(cornerRadius: 13))
    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.35)))
  }

  private func usageRow(_ title: String, value: Int, color: Color) -> some View {
    VStack(spacing: 5) {
      HStack {
        HStack(spacing: 6) {
          Circle().fill(color).frame(width: 6, height: 6)
          Text(title).foregroundStyle(.secondary)
        }
        Spacer()
        Text(compact(value)).monospacedDigit().foregroundStyle(.secondary)
      }
      .font(.caption)
      GeometryReader { geometry in
        Capsule().fill(color.opacity(0.08))
          .overlay(alignment: .leading) {
            Capsule().fill(color.opacity(0.8))
              .frame(
                width: geometry.size.width
                  * min(
                    1,
                    max(
                      0,
                      Double(value) / Double(max(model.snapshot.totalTokens, 1)))))
          }
      }
      .frame(height: 4)
    }
  }

  private var modelBreakdown: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("模型用量").font(.headline)
        Spacer()
        Text(model.snapshot.models.count > 6 ? "按 Token 排序 · 前 6 项" : "按 Token 排序")
          .font(.caption).foregroundStyle(.secondary)
      }
      Grid(horizontalSpacing: 20, verticalSpacing: 0) {
        GridRow {
          Text("模型").frame(maxWidth: .infinity, alignment: .leading)
          Text("用量记录").frame(width: 70, alignment: .trailing)
          Text("Token").frame(width: 90, alignment: .trailing)
          Text("估算费用").frame(width: 100, alignment: .trailing)
          Text("用量占比").frame(width: 110, alignment: .trailing)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.bottom, 10)
        ForEach(displayModels) { item in
          Divider().gridCellColumns(5)
          GridRow {
            VStack(alignment: .leading, spacing: 3) {
              Text(item.name.split(separator: "/").last.map(String.init) ?? item.name)
                .font(.callout.weight(.medium))
              if let provider = item.name.split(separator: "/").dropLast().first {
                Text(String(provider)).font(.caption).foregroundStyle(.secondary)
              }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .help(item.name)
            Text(item.requests.formatted()).foregroundStyle(.secondary)
            Text(compact(item.tokens))
            Text(currency(item.cost))
            HStack(spacing: 8) {
              GeometryReader { geometry in
                Capsule().fill(.quaternary)
                  .overlay(alignment: .leading) {
                    Capsule().fill(.blue.opacity(0.65))
                      .frame(
                        width: geometry.size.width
                          * min(
                            1,
                            max(
                              0,
                              Double(item.tokens) / Double(max(model.snapshot.totalTokens, 1)))))
                  }
              }
              .frame(width: 54, height: 4)
              Text(
                (Double(item.tokens) / Double(max(model.snapshot.totalTokens, 1)))
                  .formatted(.percent.precision(.fractionLength(1)))
              )
              .frame(width: 48, alignment: .trailing)
              .foregroundStyle(.secondary)
            }
          }
          .font(.callout.monospacedDigit())
          .gridColumnAlignment(.trailing)
          .padding(.vertical, 3)
        }
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 13))
    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.35)))
  }

  private var displayModels: [ModelUsage] {
    if model.isLoading && model.snapshot.requests == 0 {
      return (0..<6).map {
        ModelUsage(name: "model/placeholder-\($0)", tokens: 0, cost: 0, requests: 0)
      }
    }
    return Array(model.snapshot.models.prefix(6))
  }

  private func compact(_ value: Int) -> String {
    if value >= 1_000_000_000 {
      return String(format: "%.2fB", Double(value) / 1_000_000_000)
    }
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

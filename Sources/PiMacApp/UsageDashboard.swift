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
    let promptTokens = inputTokens + cacheReadTokens + cacheWriteTokens
    guard promptTokens > 0 else { return nil }
    return Double(cacheReadTokens) / Double(promptTokens) * 100
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

// One entry per day/model/session, rather than retaining full message bodies in the cache.
private struct UsageBucket: Codable {
  var day: Date
  var model: String
  var input = 0
  var output = 0
  var cacheRead = 0
  var cacheWrite = 0
  var tokens = 0
  var cost = 0.0
  var requests = 0
}

private struct UsageFileIndex: Codable {
  var size: Int64
  var modified: Date
  var project: String
  var buckets: [UsageBucket]
}

private struct UsageIndex: Codable {
  var root: String
  var files: [String: UsageFileIndex]
}

enum UsageScanner {
  // Scans from different period selections are serialized so an older scan cannot overwrite
  // a newer index. The lock also protects the on-disk index from concurrent read/write races.
  private nonisolated static let indexLock = NSLock()

  nonisolated static func scan(period: UsagePeriod) -> UsageSnapshot {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("PiMac/usage-index.json")
    return scan(root: root, startingAt: period.startDate, cacheURL: cache)
  }

  nonisolated static func scan(root: URL, startingAt startDate: Date?) -> UsageSnapshot {
    scan(root: root, startingAt: startDate, cacheURL: nil)
  }

  // cacheURL is injectable so tests can verify cache invalidation without touching the user's cache.
  nonisolated static func scan(root: URL, startingAt startDate: Date?, cacheURL: URL?)
    -> UsageSnapshot
  {
    indexLock.lock()
    defer { indexLock.unlock() }
    let fm = FileManager.default
    guard
      let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return UsageSnapshot() }

    var index: UsageIndex
    if let cacheURL, let data = try? Data(contentsOf: cacheURL),
      let saved = try? JSONDecoder().decode(UsageIndex.self, from: data), saved.root == root.path
    {
      index = saved
    } else {
      index = UsageIndex(root: root.path, files: [:])
    }
    var changed = false
    var seen = Set<String>()
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      let path = url.path
      seen.insert(path)
      guard
        let attributes = try? url.resourceValues(forKeys: [
          .fileSizeKey, .contentModificationDateKey,
        ]),
        let size = attributes.fileSize, let modified = attributes.contentModificationDate
      else { continue }
      if let cached = index.files[path], cached.size == Int64(size), cached.modified == modified {
        continue
      }
      // A file can be appended while we're reading it. Recheck metadata before caching it.
      if let parsed = parseFile(url, size: Int64(size), modified: modified) {
        index.files[path] = parsed
      } else {
        index.files.removeValue(forKey: path)
      }
      changed = true
    }
    let removed = index.files.keys.filter { !seen.contains($0) }
    for path in removed { index.files.removeValue(forKey: path) }
    if !removed.isEmpty { changed = true }
    if changed, let cacheURL, let data = try? JSONEncoder().encode(index) {
      try? fm.createDirectory(
        at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: cacheURL, options: .atomic)
    }

    let calendar = Calendar.current
    var snapshot = UsageSnapshot()
    var days: [Date: UsageDay] = [:]
    var models: [String: ModelUsage] = [:]
    var projects: [String: ProjectUsage] = [:]
    for file in index.files.values {
      var sessionIncluded = false
      for bucket in file.buckets
      where startDate.map({ bucket.day >= calendar.startOfDay(for: $0) }) ?? true {
        snapshot.totalTokens += bucket.tokens
        snapshot.inputTokens += bucket.input
        snapshot.outputTokens += bucket.output
        snapshot.cacheReadTokens += bucket.cacheRead
        snapshot.cacheWriteTokens += bucket.cacheWrite
        snapshot.cost += bucket.cost
        snapshot.requests += bucket.requests
        sessionIncluded = true

        var day = days[bucket.day] ?? UsageDay(date: bucket.day, tokens: 0, cost: 0)
        day.tokens += bucket.tokens
        day.cost += bucket.cost
        days[bucket.day] = day
        var model =
          models[bucket.model] ?? ModelUsage(name: bucket.model, tokens: 0, cost: 0, requests: 0)
        model.tokens += bucket.tokens
        model.cost += bucket.cost
        model.requests += bucket.requests
        models[bucket.model] = model
        var project =
          projects[file.project]
          ?? ProjectUsage(path: file.project, tokens: 0, cost: 0, sessions: 0)
        project.tokens += bucket.tokens
        project.cost += bucket.cost
        projects[file.project] = project
      }
      if sessionIncluded {
        snapshot.sessions += 1
        projects[file.project]?.sessions += 1
      }
    }
    if let startDate {
      let end = calendar.startOfDay(for: .now)
      var date = calendar.startOfDay(for: startDate)
      while date <= end {
        if days[date] == nil { days[date] = UsageDay(date: date, tokens: 0, cost: 0) }
        guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
        date = next
      }
    }
    snapshot.days = days.values.sorted { $0.date < $1.date }
    snapshot.models = models.values.sorted { $0.tokens > $1.tokens }
    snapshot.projects = projects.values.sorted { $0.tokens > $1.tokens }
    return snapshot
  }

  private nonisolated static func parseFile(_ url: URL, size: Int64, modified: Date)
    -> UsageFileIndex?
  {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    var project: String?
    var buckets: [String: UsageBucket] = [:]
    let calendar = Calendar.current
    let formatter = ISO8601DateFormatter()
    for line in data.split(separator: 0x0A) {
      // Most lines are user messages, tool calls or events; avoid JSON decoding those bodies.
      if project != nil && !line.contains(Data("\"usage\"".utf8)) { continue }
      guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
      else { continue }
      if project == nil {
        guard record["type"] as? String == "session" else { break }
        project = record["cwd"] as? String ?? "未知项目"
        continue
      }
      guard record["type"] as? String == "message",
        let message = record["message"] as? [String: Any],
        message["role"] as? String == "assistant",
        let usage = message["usage"] as? [String: Any],
        let date = recordDate(record, message: message, formatter: formatter)
      else { continue }
      let day = calendar.startOfDay(for: date)
      let model = message["model"] as? String ?? "未知模型"
      let key = "\(day.timeIntervalSince1970):\(model)"
      var bucket = buckets[key] ?? UsageBucket(day: day, model: model)
      let input = integer(usage["input"])
      let output = integer(usage["output"])
      let cacheRead = integer(usage["cacheRead"])
      let cacheWrite = integer(usage["cacheWrite"])
      bucket.input += input
      bucket.output += output
      bucket.cacheRead += cacheRead
      bucket.cacheWrite += cacheWrite
      bucket.tokens += integer(
        usage["totalTokens"], fallback: input + output + cacheRead + cacheWrite)
      let costObject = usage["cost"] as? [String: Any]
      bucket.cost += number(costObject?["total"] ?? usage["cost"])
      bucket.requests += 1
      buckets[key] = bucket
    }
    guard let project else { return nil }
    // If the file grew during parsing, retry on the next scan instead of persisting stale data.
    guard
      let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]
      ),
      attributes.fileSize.map(Int64.init) == size, attributes.contentModificationDate == modified
    else { return nil }
    return UsageFileIndex(
      size: size, modified: modified, project: project, buckets: Array(buckets.values))
  }

  private nonisolated static func integer(_ value: Any?, fallback: Int = 0) -> Int {
    if let value = value as? NSNumber { return value.intValue }
    return fallback
  }

  private nonisolated static func number(_ value: Any?) -> Double {
    (value as? NSNumber)?.doubleValue ?? 0
  }

  private nonisolated static func recordDate(
    _ record: [String: Any], message: [String: Any], formatter: ISO8601DateFormatter
  ) -> Date? {
    if let timestamp = record["timestamp"] as? String {
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: timestamp) { return date }
      formatter.formatOptions = [.withInternetDateTime]
      if let date = formatter.date(from: timestamp) { return date }
    }
    if let timestamp = message["timestamp"] as? NSNumber {
      return Date(timeIntervalSince1970: timestamp.doubleValue / 1_000)
    }
    return nil
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
      Button(action: model.reload) {
        Image(systemName: "arrow.clockwise")
      }
      .disabled(model.isLoading)
      .help("重新统计")
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
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
            "模型请求", value: model.snapshot.requests.formatted(), icon: "sparkles", tint: .purple)
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

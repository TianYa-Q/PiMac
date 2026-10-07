import Foundation

/// Presentation-only aggregation of Server-owned daily buckets. Never reads transcripts or prices tokens.
enum T3UsageSummary {
  typealias JSON = [String: Any]

  static func input(period: UsagePeriod, now: Date = .now, timeZone: TimeZone = .current) -> JSON {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let end = calendar.startOfDay(for: now)
    let days: Int? = period == .week ? 6 : period == .month ? 29 : nil
    let start = days.flatMap { calendar.date(byAdding: .day, value: -$0, to: end) }
    let formatter = dayFormatter(timeZone)
    return [
      "sinceDay": start.map { formatter.string(from: $0) } ?? "1970-01-01",
      "untilDay": formatter.string(from: end), "timeZone": timeZone.identifier,
      "resolution": "day",
    ]
  }

  static func snapshot(_ summary: JSON, period: UsagePeriod) throws -> UsageSnapshot {
    guard let version = summary["contractVersion"] as? Int, (4...6).contains(version),
      let buckets = summary["buckets"] as? [JSON], let sources = summary["sources"] as? [JSON],
      let zoneID = summary["timeZone"] as? String, let zone = TimeZone(identifier: zoneID)
    else { throw T3DesktopClient.ClientError.rejected }
    let formatter = dayFormatter(zone)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    var result = UsageSnapshot()
    var days: [Date: UsageDay] = [:]
    var models: [String: ModelUsage] = [:]
    var unpriced = 0
    for bucket in buckets {
      guard let dayString = bucket["day"] as? String, let date = formatter.date(from: dayString),
        let model = bucket["model"] as? String, let totals = bucket["totals"] as? JSON
      else { throw T3DesktopClient.ClientError.rejected }
      let input = UsageArithmetic.integer(totals["uncachedInputTokens"])
      let output = UsageArithmetic.integer(totals["outputTokens"])
      let read = UsageArithmetic.integer(totals["cachedInputTokens"])
      let write = UsageArithmetic.integer(totals["cacheCreationTokens"])
      // Reasoning is already included in output, not an additional category.
      let tokens = UsageArithmetic.add(UsageArithmetic.add(input, output), UsageArithmetic.add(read, write))
      let cost = UsageArithmetic.cost(bucket["costUsd"])
      let requests = UsageArithmetic.integer(bucket["records"])
      result.inputTokens = UsageArithmetic.add(result.inputTokens, input)
      result.outputTokens = UsageArithmetic.add(result.outputTokens, output)
      result.cacheReadTokens = UsageArithmetic.add(result.cacheReadTokens, read)
      result.cacheWriteTokens = UsageArithmetic.add(result.cacheWriteTokens, write)
      result.totalTokens = UsageArithmetic.add(result.totalTokens, tokens)
      result.cost = UsageArithmetic.add(result.cost, cost)
      result.requests = UsageArithmetic.add(result.requests, requests)
      unpriced = UsageArithmetic.add(unpriced, UsageArithmetic.integer(bucket["unpricedRecords"]))
      var day = days[date] ?? UsageDay(date: date, tokens: 0, cost: 0)
      day.tokens = UsageArithmetic.add(day.tokens, tokens)
      day.cost = UsageArithmetic.add(day.cost, cost)
      days[date] = day
      var item = models[model] ?? ModelUsage(name: model, tokens: 0, cost: 0, requests: 0)
      item.tokens = UsageArithmetic.add(item.tokens, tokens)
      item.cost = UsageArithmetic.add(item.cost, cost)
      item.requests = UsageArithmetic.add(item.requests, requests)
      models[model] = item
    }
    // Bucket session counts overlap across days/models. Use the Server's source counts instead.
    for source in sources {
      result.sessions = UsageArithmetic.add(result.sessions, UsageArithmetic.integer(source["distinctSessions"]))
      let status = source["status"] as? String ?? "failed"
      if status == "partial" || status == "failed" {
        result.coverageWarnings.append("部分用量来源读取不完整，汇总可能偏低。")
      }
    }
    if unpriced > 0 { result.coverageWarnings.append("\(unpriced) 条记录缺少定价；Token 已计入，费用未计入。") }
    result.coverageWarnings = Array(Set(result.coverageWarnings)).sorted()
    if period != .all, let since = summary["sinceDay"] as? String,
      let until = summary["untilDay"] as? String,
      var date = formatter.date(from: since), let end = formatter.date(from: until)
    {
      // Only bounded UI windows are filled; never expand an all-history response into decades of zeros.
      for _ in 0..<31 {
        guard date <= end else { break }
        if days[date] == nil { days[date] = UsageDay(date: date, tokens: 0, cost: 0) }
        guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
        date = next
      }
    }
    result.days = days.values.sorted { $0.date < $1.date }
    result.models = models.values.sorted { $0.tokens == $1.tokens ? $0.name < $1.name : $0.tokens > $1.tokens }
    return result
  }

  private static func dayFormatter(_ zone: TimeZone) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = zone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }
}

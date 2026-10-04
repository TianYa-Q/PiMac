import Foundation

/// Treat local transcript metrics as untrusted input. Saturation keeps aggregation total
/// and prevents corrupt or adversarial records from crashing the dashboard.
enum UsageArithmetic {
  static func integer(_ value: Any?, fallback: Int = 0) -> Int {
    guard let number = AccountUsageSnapshot.number(value), number >= 0,
      number.rounded(.towardZero) == number, number < Double(Int.max)
    else { return fallback }
    return Int(number)
  }

  static func cost(_ value: Any?) -> Double {
    guard let number = AccountUsageSnapshot.number(value), number >= 0 else { return 0 }
    return number
  }

  static func add(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : sum
  }

  static func add(_ lhs: Double, _ rhs: Double) -> Double {
    let sum = lhs + rhs
    return sum.isFinite ? sum : Double.greatestFiniteMagnitude
  }
}

/// Export only aggregated metrics, not messages or credentials. Quote cells and neutralize
/// spreadsheet formulas in model/project labels before producing RFC 4180 rows.
enum UsageCSV {
  static func export(_ snapshot: UsageSnapshot) -> String {
    var rows = [["category", "name", "tokens", "cost_usd", "count"]]
    rows.append([
      "total", "all", String(snapshot.totalTokens), String(snapshot.cost),
      String(snapshot.requests),
    ])
    for model in snapshot.models {
      rows.append([
        "model", model.name, String(model.tokens), String(model.cost), String(model.requests),
      ])
    }
    for project in snapshot.projects {
      rows.append([
        "project", project.path, String(project.tokens), String(project.cost),
        String(project.sessions),
      ])
    }
    return rows.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
  }

  private static func cell(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let safe = trimmed.first.map { "=+-@".contains($0) } == true ? "'" + value : value
    return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

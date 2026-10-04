import CoreFoundation
import Foundation

/// The publication timestamp is not the time the provider was queried.
/// Keep numeric validation and freshness policy independent of SwiftUI and RPC state.
enum AccountUsageSnapshot {
  static func number(_ value: Any?) -> Double? {
    guard let value = value as? NSNumber,
      CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite
    else { return nil }
    return value.doubleValue
  }

  static func date(_ value: Any?, milliseconds: Bool = false) -> Date? {
    guard let value = number(value), value >= 0 else { return nil }
    let seconds = milliseconds ? value / 1_000 : value
    // Reject dates outside Foundation's supported calendar range.
    guard seconds <= Date.distantFuture.timeIntervalSince1970 else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }

  static func percent(_ value: Any?) -> Double? {
    guard let value = number(value), (0...100).contains(value) else { return nil }
    return value
  }

  enum Freshness: Equatable {
    case unknown, fresh, stale, clockSkew
  }

  static func freshness(
    capturedAt: Date?, now: Date, maxAge: TimeInterval = 180
  ) -> Freshness {
    guard let capturedAt else { return .unknown }
    let age = now.timeIntervalSince(capturedAt)
    if age < -5 { return .clockSkew }
    return age >= maxAge ? .stale : .fresh
  }
}

import Foundation

/// Shared UserDefaults preference; resizing never re-keys the conversation/editor.
enum SidebarWidth {
  static let storageKey = "workspaceSidebarWidth"
  static let defaultValue = 292.0
  static let minimum = 250.0
  static let maximum = 360.0

  static func clamped(_ value: Double) -> Double {
    guard value.isFinite else { return defaultValue }
    return min(maximum, max(minimum, value))
  }
}

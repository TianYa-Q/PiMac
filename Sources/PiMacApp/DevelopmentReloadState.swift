import Foundation

/// One-way transaction per app lifetime. Failure is terminal, not an infinite retry loop.
struct DevelopmentReloadState {
  enum Phase: String { case watching, draining, exiting, failed }
  private(set) var phase: Phase = .watching
  private var idleSince: Date?

  mutating func observeIdle(_ idle: Bool, now: Date) -> Bool {
    guard phase == .watching else { return false }
    if !idle {
      idleSince = nil
      return false
    }
    if idleSince == nil { idleSince = now }
    return now.timeIntervalSince(idleSince!) >= 2
  }

  /// Explicit coding batches are a safety barrier, not a timeout-based heuristic.
  static func editsPending(directory: URL?) -> Bool {
    guard let directory else { return false }
    do {
      return try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      ).contains { $0.pathExtension == "json" }
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return false
    } catch {
      return true  // An unreadable barrier cannot authorize a restart.
    }
  }

  mutating func begin() { phase = .draining }
  mutating func readyToExit() { phase = .exiting }
  mutating func fail() { phase = .failed }
}

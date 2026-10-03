import Foundation

/// One-way transaction per app lifetime. Failure is terminal, not an infinite retry loop.
struct DevelopmentReloadState {
  enum Phase: String { case watching, draining, exiting, failed }
  private(set) var phase: Phase = .watching
  private var idleSince: Date?

  mutating func observeIdle(_ idle: Bool, now: Date) -> Bool {
    guard phase == .watching else { return false }
    if !idle { idleSince = nil; return false }
    if idleSince == nil { idleSince = now }
    return now.timeIntervalSince(idleSince!) >= 2
  }

  mutating func begin() { phase = .draining }
  mutating func readyToExit() { phase = .exiting }
  mutating func fail() { phase = .failed }
}

import Foundation
import SwiftUI
import Testing

@testable import PiMacApp

@MainActor
struct SidebarWidthTests {
  @Test func widthPreferenceSurvivesViewRecreation() throws {
    let suite = "pimac-sidebar-width-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = AppStorage(
      wrappedValue: SidebarWidth.defaultValue, SidebarWidth.storageKey, store: defaults)
    #expect(first.wrappedValue == 292)
    first.wrappedValue = SidebarWidth.clamped(327)
    let restoredDefaults = try #require(UserDefaults(suiteName: suite))
    let restored = AppStorage(
      wrappedValue: SidebarWidth.defaultValue, SidebarWidth.storageKey, store: restoredDefaults)
    #expect(restored.wrappedValue == 327)
    #expect(restoredDefaults.double(forKey: SidebarWidth.storageKey) == 327)
  }

  @Test func malformedAndOutOfRangeWidthsStayWithinLayoutBounds() {
    #expect(SidebarWidth.clamped(200) == 250)
    #expect(SidebarWidth.clamped(500) == 360)
    #expect(SidebarWidth.clamped(318) == 318)
    #expect(SidebarWidth.clamped(.nan) == 292)
    #expect(SidebarWidth.clamped(.infinity) == 292)
    #expect(SidebarWidth.clamped(-.infinity) == 292)
  }
}

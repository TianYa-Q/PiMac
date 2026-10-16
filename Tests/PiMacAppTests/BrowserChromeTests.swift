import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct BrowserChromeTests {
  @Test func siteLabelsPreservePortsAndDoNotExposePathsOrQueries() {
    let local = BrowserTabPresentation(
      tab: T3BrowserTab(
        id: "local", title: "  工作台  ", url: "http://localhost:5173/dashboard?token=fixture",
        failure: nil, revealID: nil))
    #expect(local.title == "工作台")
    #expect(local.site == "localhost:5173")
    #expect(!local.isSecure)
    let secure = BrowserTabPresentation(
      tab: T3BrowserTab(
        id: "remote", title: "", url: "https://www.example.com:443/path?q=value",
        failure: nil, revealID: nil))
    #expect(secure.site == "example.com")
    #expect(secure.title == "example.com")
    #expect(secure.isSecure)
    #expect(secure.monogram == "E")
    #expect((0..<6).contains(secure.colorIndex))
    let otherPage = BrowserTabPresentation(
      tab: T3BrowserTab(
        id: "other", title: "其他页面", url: "https://www.example.com/other",
        failure: nil, revealID: nil))
    #expect(otherPage.colorIndex == secure.colorIndex)
    #expect(otherPage.monogram == secure.monogram)
    let blank = BrowserTabPresentation(
      tab: T3BrowserTab(
        id: "blank", title: "", url: "", failure: nil, revealID: nil))
    #expect(blank.site == "新标签页")
    #expect(blank.monogram.isEmpty)
  }

  @Test func narrowPanelsUseIconRailAndOverlayInsteadOfSqueezingPage() {
    #expect(!BrowserChromeLayout.defaultsToExpanded(availableWidth: 380))
    #expect(BrowserChromeLayout.defaultsToExpanded(availableWidth: 1100))
    #expect(BrowserChromeLayout.sidebarWidth(availableWidth: 380, expanded: false) == 54)
    #expect(BrowserChromeLayout.sidebarWidth(availableWidth: 1100, expanded: true) == 208)
    #expect(BrowserChromeLayout.usesOverlay(availableWidth: 380, expanded: true))
    #expect(!BrowserChromeLayout.usesOverlay(availableWidth: 380, expanded: false))
    #expect(!BrowserChromeLayout.usesOverlay(availableWidth: 1100, expanded: true))
  }

  @Test func closingSelectedTabChoosesSurvivorAndEmptyStateStaysOpen() {
    let model = BrowserPreviewModel()
    defer { model.stop() }
    let first = T3BrowserTab(id: "a", title: "A", url: "", failure: nil, revealID: "show-a")
    let second = T3BrowserTab(id: "b", title: "B", url: "", failure: nil, revealID: nil)
    model.apply([first, second])
    model.select("b")
    #expect(model.selectedTab?.id == "b")
    model.apply([first])
    #expect(model.selection == "a")
    model.apply([])
    #expect(model.selectedTab == nil)
    #expect(model.visible)
    #expect(!model.canManageTabs)
    model.updateTabs(closing: nil)
    #expect(!model.isUpdatingTabs)
    model.stop()
    #expect(!model.visible)
  }
}

import Foundation

/// 只派生展示数据，不再存一份标签状态；站点标记由域名生成，不额外请求 favicon 或泄露浏览记录。
struct BrowserTabPresentation: Equatable {
  let title: String
  let site: String
  let monogram: String
  let colorIndex: Int
  let isSecure: Bool

  init(tab: T3BrowserTab) {
    let components = URLComponents(string: tab.url)
    let host = components?.host ?? ""
    let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    let port = components?.port
    let standardPort =
      (components?.scheme == "https" && port == 443)
      || (components?.scheme == "http" && port == 80)
    let suffix = standardPort ? "" : (port.map { ":\($0)" } ?? "")
    site = domain.isEmpty ? "新标签页" : domain + suffix
    let trimmed = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
    title = trimmed.isEmpty ? site : trimmed
    monogram = domain.first.map { String($0).uppercased() } ?? ""
    colorIndex = domain.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 6 }
    isSecure = components?.scheme?.lowercased() == "https"
  }
}

/// 窄的停靠面板使用图标轨道，独立窗口默认完整 Tab 栏；用户可显式展开或收起。
enum BrowserChromeLayout {
  static func sidebarWidth(availableWidth: Double, expanded: Bool) -> Double {
    expanded ? min(208, max(152, availableWidth * 0.24)) : 54
  }
  static func defaultsToExpanded(availableWidth: Double) -> Bool { availableWidth >= 720 }
  static func usesOverlay(availableWidth: Double, expanded: Bool) -> Bool {
    expanded && availableWidth < 600
  }
}

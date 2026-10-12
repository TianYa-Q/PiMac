import Foundation
import Testing
@testable import PiMacApp

struct SessionTreeTests {
  private func sessions(_ paths: [String]) -> [SessionItem] {
    paths.map { SessionItem(path: $0, title: $0, modifiedAt: .distantPast) }
  }

  @Test func collapsesAndExpandsMultipleLevelsWithoutSplittingFamilies() {
    let tree = SessionTree(
      sessions: sessions(["child", "other", "grandchild", "parent", "sibling"]),
      parentPaths: ["child": "parent", "grandchild": "child", "sibling": "parent"])
    #expect(tree.roots.map(\.path) == ["parent", "other"])
    #expect(tree.rows(expandedPaths: [], rootLimit: 10).map(\.id) == ["parent", "other"])
    let expanded = tree.rows(expandedPaths: ["parent", "child"], rootLimit: 1)
    #expect(expanded.map(\.id) == ["parent", "child", "grandchild", "sibling"])
    #expect(expanded.map(\.depth) == [0, 1, 2, 1])
    #expect(expanded.map(\.childCount) == [2, 1, 0, 0])
    #expect(tree.rows(expandedPaths: ["child"], rootLimit: 1).map(\.id) == ["parent"])
    #expect(tree.ancestorPaths(of: "grandchild") == ["child", "parent"])
  }

  @Test func filteredParentsDoNotHideChildren() {
    let tree = SessionTree(sessions: sessions(["child", "normal"]), parentPaths: ["child": "hidden"])
    #expect(tree.roots.map(\.path) == ["child", "normal"])
    #expect(tree.ancestorPaths(of: "child").isEmpty)
  }

  @Test func brokenCyclesKeepEverySessionReachable() {
    let tree = SessionTree(
      sessions: sessions(["leaf", "a", "b", "self", "normal"]),
      parentPaths: ["leaf": "a", "a": "b", "b": "a", "self": "self", "missing": "normal"])
    #expect(tree.roots.map(\.path) == ["a", "self", "normal"])
    let rows = tree.rows(expandedPaths: ["a", "b", "self"], rootLimit: 10)
    #expect(rows.map(\.id) == ["a", "leaf", "b", "self", "normal"])
    #expect(Set(rows.map(\.id)).count == 5)
    #expect(tree.ancestorPaths(of: "b") == ["a"])
  }

  @Test func emptyAndZeroLimitAreLegal() {
    #expect(SessionTree(sessions: [], parentPaths: [:]).rows(expandedPaths: [], rootLimit: 10).isEmpty)
    let tree = SessionTree(sessions: sessions(["a"]), parentPaths: [:])
    #expect(tree.rows(expandedPaths: [], rootLimit: 0).isEmpty)
    #expect(tree.rows(expandedPaths: [], rootLimit: -1).isEmpty)
  }

  @Test func deepDelegationUsesIterativeTraversal() {
    let paths = (0..<2000).map { String($0) }
    let tree = SessionTree(sessions: sessions(paths), parentPaths: Dictionary(
      uniqueKeysWithValues: (1..<2000).map { (String($0), String($0 - 1)) }))
    #expect(tree.rows(expandedPaths: Set(paths), rootLimit: 1).count == 2000)
    #expect(tree.ancestorPaths(of: "1999").count == 1999)
  }
}

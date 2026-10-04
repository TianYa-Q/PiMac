import Foundation

/// Local presentation rules only; the Server remains authoritative for Git operations.
enum GitWorkspacePresentation {
  enum FileScope: String, CaseIterable, Identifiable {
    case all = "全部文件"
    case selected = "仅看已选"
    case unselected = "仅看未选"
    var id: String { rawValue }
  }

  enum FileSort: String, CaseIterable, Identifiable {
    case server = "默认顺序"
    case path = "文件路径"
    case changes = "变更最多"
    var id: String { rawValue }
  }

  static func filteredFiles(
    _ files: [GitWorkspaceStatus.File], query: String,
    scope: FileScope = .all, selected: Set<String> = [], sort: FileSort = .server
  )
    -> [GitWorkspaceStatus.File]
  {
    let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let filtered = files.filter { file in
      let inScope =
        scope == .all
        || (scope == .selected && selected.contains(file.path))
        || (scope == .unselected && !selected.contains(file.path))
      return inScope && terms.allSatisfy { file.path.localizedStandardContains($0) }
    }
    guard sort != .server else { return filtered }
    return filtered.sorted { lhs, rhs in
      if sort == .changes {
        let leftCount = saturatedAdd(lhs.insertions, lhs.deletions)
        let rightCount = saturatedAdd(rhs.insertions, rhs.deletions)
        if leftCount != rightCount { return leftCount > rightCount }
      }
      let order = lhs.path.localizedStandardCompare(rhs.path)
      return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
    }
  }

  /// Saturate server counts instead of allowing a malformed/huge snapshot to overflow the UI.
  static func selectedChanges(_ files: [GitWorkspaceStatus.File], selected: Set<String>)
    -> (insertions: Int, deletions: Int)
  {
    return files.filter { selected.contains($0.path) }.reduce((0, 0)) {
      (saturatedAdd($0.0, $1.insertions), saturatedAdd($0.1, $1.deletions))
    }
  }

  private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
    return overflow ? Int.max : sum
  }

  /// Toggle only visible files, preserving selections hidden by the current filter.
  static func toggledSelection(_ selected: Set<String>, visible: [GitWorkspaceStatus.File]) -> Set<
    String
  > {
    let paths = Set(visible.map(\.path))
    return paths.isSubset(of: selected) ? selected.subtracting(paths) : selected.union(paths)
  }

  static func filteredBranches(_ branches: [String], query: String, current: String?) -> [String] {
    let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    return Array(Set(branches)).filter { branch in
      terms.allSatisfy { branch.localizedStandardContains($0) }
    }.sorted { lhs, rhs in
      if lhs == current { return true }
      if rhs == current { return false }
      let order = lhs.localizedStandardCompare(rhs)
      return order == .orderedSame ? lhs < rhs : order == .orderedAscending
    }
  }

  static func branchNameError(_ input: String) -> String? {
    let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return "请输入分支名称。" }
    guard name != "@", !name.hasPrefix("-"), !name.hasSuffix("."),
      !name.contains(".."), !name.contains("@{"),
      !name.unicodeScalars.contains(where: {
        $0.value <= 32 || $0.value == 127 || "~^:?*[\\".unicodeScalars.contains($0)
      })
    else { return "分支名不能包含空格、控制字符或 Git 保留字符。" }
    let components = name.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock") })
    else {
      return "分支路径不能含空段、以点开头或以 .lock 结尾。"
    }
    return nil
  }
}

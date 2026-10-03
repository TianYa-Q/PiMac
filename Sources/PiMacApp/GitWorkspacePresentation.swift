import Foundation

/// Local presentation rules only; the Server remains authoritative for Git operations.
enum GitWorkspacePresentation {
  enum FileScope: String, CaseIterable, Identifiable {
    case all = "全部文件"
    case selected = "仅看已选"
    var id: String { rawValue }
  }

  static func filteredFiles(
    _ files: [GitWorkspaceStatus.File], query: String,
    scope: FileScope = .all, selected: Set<String> = []
  )
    -> [GitWorkspaceStatus.File]
  {
    let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    return files.filter { file in
      (scope == .all || selected.contains(file.path))
        && terms.allSatisfy { file.path.localizedStandardContains($0) }
    }
  }

  /// Saturate server counts instead of allowing a malformed/huge snapshot to overflow the UI.
  static func selectedChanges(_ files: [GitWorkspaceStatus.File], selected: Set<String>)
    -> (insertions: Int, deletions: Int)
  {
    func add(_ total: Int, _ count: Int) -> Int {
      let (sum, overflow) = total.addingReportingOverflow(max(0, count))
      return overflow ? Int.max : sum
    }
    return files.filter { selected.contains($0.path) }.reduce((0, 0)) {
      (add($0.0, $1.insertions), add($0.1, $1.deletions))
    }
  }

  /// Toggle only visible files, preserving selections hidden by the current filter.
  static func toggledSelection(_ selected: Set<String>, visible: [GitWorkspaceStatus.File]) -> Set<
    String
  > {
    let paths = Set(visible.map(\.path))
    return paths.isSubset(of: selected) ? selected.subtracting(paths) : selected.union(paths)
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

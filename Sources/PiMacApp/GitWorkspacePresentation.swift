import Foundation

/// Local presentation rules only; the Server remains authoritative for Git operations.
enum GitWorkspacePresentation {
  static func filteredFiles(_ files: [GitWorkspaceStatus.File], query: String)
    -> [GitWorkspaceStatus.File]
  {
    let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !terms.isEmpty else { return files }
    return files.filter { file in
      terms.allSatisfy { file.path.localizedStandardContains($0) }
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

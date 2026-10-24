import Foundation

/// 只关联工具明确读取过的本地日志；不从自然语言、工具输出或目录扫描猜测文件。
struct TaskLogSource: Equatable, Sendable, Identifiable {
  let root: URL
  let file: URL
  var id: String { root.path + "\n" + file.path }

  static func latest(in entries: [ChatEntry], root: URL) -> Self? {
    var remaining = entries
    while let entry = remaining.popLast() {
      remaining.append(contentsOf: entry.childToolEntries)
      guard entry.kind == .tool, let input = entry.toolInput else { continue }
      let paths: [(String, URL)]
      switch entry.toolName {
      case "read": paths = [(ReadToolSummary(input: input).path, root)]
      case "bash": paths = localTailPaths(input, root: root)
      default: continue
      }
      for (path, directory) in paths.reversed() {
        guard path.hasSuffix(".log"), !path.contains("\0") else { continue }
        let file = URL(
          fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory.path, isDirectory: true)
        )
        .standardizedFileURL
        let base = root.standardizedFileURL
        guard file.path.hasPrefix(base.path + "/") else { continue }
        return Self(root: base, file: file)
      }
    }
    return nil
  }

  /// 仅识别简单本地 tail 和字面量 cd。拒绝变量、重定向、管道与子 shell；
  /// 例如 ssh 'tail …' 绝不会变成本机文件读取，更不会执行这段命令。
  static func localTailPaths(_ input: String, root: URL) -> [(String, URL)] {
    let source = input.hasPrefix("$ ") ? String(input.dropFirst(2)) : input
    guard !source.contains(where: { "$`<>|()".contains($0) }) else { return [] }
    var statements: [[String]] = []
    var tokens: [String] = []
    var word = ""
    var quote: Character?
    var escaped = false
    for character in source {
      if escaped {
        word.append(character)
        escaped = false
        continue
      }
      if character == "\\", quote != "'" {
        escaped = true
        continue
      }
      if let current = quote {
        if character == current { quote = nil } else { word.append(character) }
      } else if character == "'" || character == "\"" {
        quote = character
      } else if character == ";" || character == "\n" || character == "&" {
        if !word.isEmpty {
          tokens.append(word)
          word = ""
        }
        statements.append(tokens)
        tokens = []
      } else if character.isWhitespace {
        if !word.isEmpty {
          tokens.append(word)
          word = ""
        }
      } else {
        word.append(character)
      }
    }
    guard quote == nil, !escaped else { return [] }
    if !word.isEmpty { tokens.append(word) }
    statements.append(tokens)
    var directory = root
    var paths: [(String, URL)] = []
    for tokens in statements where !tokens.isEmpty {
      if tokens[0] == "cd" {
        guard tokens.count == 2, !tokens[1].hasPrefix("~") else { return [] }
        directory =
          URL(
            fileURLWithPath: tokens[1],
            relativeTo: URL(fileURLWithPath: directory.path, isDirectory: true)
          )
          .standardizedFileURL
      } else if ["tail", "/usr/bin/tail"].contains(tokens[0]) {
        paths += tokens.dropFirst().filter { !$0.hasPrefix("-") && $0.hasSuffix(".log") }
          .map { ($0, directory) }
      }
    }
    return paths
  }
}

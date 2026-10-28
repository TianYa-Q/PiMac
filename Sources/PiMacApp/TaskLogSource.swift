import Foundation

/// 只关联工具明确读取或写入的本地日志；不从自然语言、工具输出或目录扫描猜测文件。
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
      case "bash": paths = localLogPaths(input, root: root)
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

  private struct ShellToken {
    let value: String
    let isOperator: Bool
    let isLiteral: Bool
  }

  /// 只做词法识别，不运行 shell：保留引号边界，避免把 echo/ssh/sh -c 中的文本当命令。
  /// 变量可以出现在普通参数中，但不能成为关联路径；复杂 shell 结构宁可不关联。
  private static func shellTokens(_ source: String) -> [ShellToken]? {
    let characters = Array(source)
    var tokens: [ShellToken] = []
    var word = ""
    var started = false
    var literal = true
    var quote: Character?
    var index = 0
    func flush() {
      if started {
        tokens.append(ShellToken(value: word, isOperator: false, isLiteral: literal))
      }
      word = ""
      started = false
      literal = true
    }
    while index < characters.count {
      let character = characters[index]
      if character == "\\", quote != "'" {
        guard index + 1 < characters.count else { return nil }
        let next = characters[index + 1]
        if next != "\n" {
          if quote == "\"", !"$`\"\\".contains(next) { word.append("\\") }
          word.append(next)
          started = true
        }
        index += 2
        continue
      }
      if let current = quote {
        if character == current {
          quote = nil
        } else {
          if current == "\"", character == "$" || character == "`" {
            // 命令替换的嵌套引号需要完整 shell AST，不在这里近似解释。
            if character == "`" || (index + 1 < characters.count && characters[index + 1] == "(") {
              return nil
            }
            literal = false
          }
          word.append(character)
        }
      } else if character == "'" || character == "\"" {
        quote = character
        started = true
      } else if character == "#", !started {
        while index < characters.count, characters[index] != "\n" { index += 1 }
        continue
      } else if "`()<{}".contains(character) {
        return nil
      } else if ";\n&|>".contains(character) {
        flush()
        var symbol = character == "\n" ? ";" : String(character)
        if index + 1 < characters.count {
          let next = characters[index + 1]
          if (character == "&" && (next == "&" || next == ">"))
            || (character == "|" && next == "|")
            || (character == ">" && (next == ">" || next == "&"))
          {
            symbol.append(next)
            index += 1
            if symbol == "&>", index + 1 < characters.count, characters[index + 1] == ">" {
              symbol.append(">")
              index += 1
            }
          }
        }
        tokens.append(ShellToken(value: symbol, isOperator: true, isLiteral: true))
      } else if character.isWhitespace {
        flush()
      } else {
        if "$*?[]~".contains(character) { literal = false }
        word.append(character)
        started = true
      }
      index += 1
    }
    guard quote == nil else { return nil }
    flush()
    return tokens
  }

  /// 支持本地读取、输出/追加重定向及 tee，包括管道和后台执行。
  /// cd 只接受字面量；不展开变量、远端命令、子 shell 或控制流，最终路径仍由工作区边界校验。
  static func localLogPaths(_ input: String, root: URL) -> [(String, URL)] {
    let source = input.hasPrefix("$ ") ? String(input.dropFirst(2)) : input
    guard let tokens = shellTokens(source) else { return [] }
    var directory = root
    var paths: [(String, URL)] = []
    var start = 0
    let separators = [";", "&&", "||", "|", "&"]
    for end in 0...tokens.count {
      let separator = end < tokens.count ? tokens[end] : nil
      if let separator {
        guard separator.isOperator, separators.contains(separator.value) else { continue }
      }
      let followsPipe = start > 0 && tokens[start - 1].value == "|"
      let statement = Array(tokens[start..<end])
      start = end + 1
      // 后台的整个 && 链可能在子 shell 改目录，不能把目录状态泄漏给后续命令。
      if separator?.value == "&", end + 1 < tokens.count, directory != root { return [] }
      guard let command = statement.first, !command.isOperator else { continue }
      if [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
        "function", "pushd", "popd", "source", ".", "!", "eval",
      ]
      .contains(command.value) {
        return []
      }
      if command.value == "cd" {
        let arguments = statement.dropFirst().filter { $0.value != "--" }
        guard arguments.count == 1, let target = arguments.first,
          target.isLiteral, !target.isOperator, !target.value.isEmpty,
          !target.value.hasPrefix("-"), separator?.value != "|", separator?.value != "&",
          !followsPipe
        else { return [] }
        directory =
          URL(
            fileURLWithPath: target.value,
            relativeTo: URL(fileURLWithPath: directory.path, isDirectory: true)
          ).standardizedFileURL
        continue
      }
      let readsFiles =
        command.isLiteral
        && [
          "tail", "head", "cat", "tee", "/usr/bin/tail", "/usr/bin/head", "/bin/cat",
          "/usr/bin/tee",
        ]
        .contains(command.value)
      var index = 1
      while index < statement.count {
        let token = statement[index]
        if token.isOperator {
          guard [">", ">>", "&>", "&>>", ">&"].contains(token.value),
            index + 1 < statement.count, !statement[index + 1].isOperator
          else { return [] }
          let target = statement[index + 1]
          // 2>&1 是描述符复制，不是名为 1 的文件；字面量日志目标才可关联。
          if target.isLiteral, target.value.hasSuffix(".log") {
            paths.append((target.value, directory))
          }
          index += 2
        } else {
          if readsFiles, token.isLiteral, !token.value.hasPrefix("-"), token.value.hasSuffix(".log")
          {
            paths.append((token.value, directory))
          }
          index += 1
        }
      }
    }
    return paths
  }
}

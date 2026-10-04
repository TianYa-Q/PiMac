import Foundation

/// Words are ANDed; quotes preserve phrases, - excludes, title:/text: scope terms.
/// Unclosed quotes remain searchable while typing. Unknown prefixes stay literal.
struct SessionSearchQuery: Equatable, Sendable {
  let required: [String]
  let excluded: [String]
  let titleRequired: [String]
  let titleExcluded: [String]
  let textRequired: [String]
  let textExcluded: [String]

  init(_ text: String) {
    var required: [String] = []
    var excluded: [String] = []
    var titleRequired: [String] = []
    var titleExcluded: [String] = []
    var textRequired: [String] = []
    var textExcluded: [String] = []
    var token = ""
    var quoted = false
    func flush() {
      defer { token = "" }
      guard !token.isEmpty else { return }
      let negative = token.hasPrefix("-")
      var value = negative ? String(token.dropFirst()) : token
      var scope = ""
      for prefix in ["title:", "text:"] where value.lowercased().hasPrefix(prefix) {
        scope = prefix
        value = String(value.dropFirst(prefix.count))
        break
      }
      guard !value.isEmpty else { return }
      switch (scope, negative) {
      case ("title:", false): titleRequired.append(value)
      case ("title:", true): titleExcluded.append(value)
      case ("text:", false): textRequired.append(value)
      case ("text:", true): textExcluded.append(value)
      case (_, true): excluded.append(value)
      default: required.append(value)
      }
    }
    for character in text {
      if character == "\"" {
        quoted.toggle()
      } else if character.isWhitespace && !quoted {
        flush()
      } else {
        token.append(character)
      }
    }
    flush()
    self.required = required
    self.excluded = excluded
    self.titleRequired = titleRequired
    self.titleExcluded = titleExcluded
    self.textRequired = textRequired
    self.textExcluded = textExcluded
  }

  var isEmpty: Bool {
    required.isEmpty && excluded.isEmpty && titleRequired.isEmpty && titleExcluded.isEmpty
      && textRequired.isEmpty && textExcluded.isEmpty
  }

  private func contains(_ term: String, in texts: [String]) -> Bool {
    texts.contains { $0.localizedStandardContains(term) }
  }

  func matches(_ texts: [String]) -> Bool {
    !isEmpty && required.allSatisfy { contains($0, in: texts) }
      && !excluded.contains { contains($0, in: texts) }
  }

  func acceptsTitle(_ title: String) -> Bool {
    titleRequired.allSatisfy { contains($0, in: [title]) }
      && !titleExcluded.contains { contains($0, in: [title]) }
      && !excluded.contains { contains($0, in: [title]) }
  }

  func needsMessages(for title: String) -> Bool {
    acceptsTitle(title)
      && (!textRequired.isEmpty || !textExcluded.isEmpty || !excluded.isEmpty
        || !required.allSatisfy { contains($0, in: [title]) })
  }

  func matches(title: String, messages: [String]) -> Bool {
    matches([title] + messages) && acceptsTitle(title)
      && textRequired.allSatisfy { contains($0, in: messages) }
      && !textExcluded.contains { contains($0, in: messages) }
  }

  func snippetTerm(for title: String) -> String? {
    textRequired.first ?? required.first { !contains($0, in: [title]) }
  }
}

import Foundation

/// Small, forgiving query grammar: words are ANDed, quotes preserve phrases, - excludes.
/// Unclosed quotes are treated as a phrase while the user is still typing.
struct SessionSearchQuery: Equatable, Sendable {
  let required: [String]
  let excluded: [String]

  init(_ text: String) {
    var required: [String] = []
    var excluded: [String] = []
    var token = ""
    var quoted = false
    func flush() {
      guard !token.isEmpty else { return }
      if token.hasPrefix("-"), token.count > 1 {
        excluded.append(String(token.dropFirst()))
      } else if token != "-" {
        required.append(token)
      }
      token = ""
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
  }

  var isEmpty: Bool { required.isEmpty && excluded.isEmpty }

  func matches(_ texts: [String]) -> Bool {
    !isEmpty
      && required.allSatisfy { term in texts.contains { $0.localizedStandardContains(term) } }
      && !excluded.contains { term in texts.contains { $0.localizedStandardContains(term) } }
  }
}

import Foundation

/// SwiftUI sheet identity must be scoped locally, not to a process's wire request ID.
struct ExtensionDialogPresentation: Identifiable {
  let dialog: ExtensionDialog
  var id: UUID { dialog.presentationID }
}

/// Preserve option indices and wire values, including duplicate labels.
struct ExtensionOptionSearch {
  struct Option: Identifiable, Equatable {
    let id: Int
    let value: String
  }

  static func filter(_ options: [String], query: String) -> [Option] {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    return options.enumerated().compactMap { index, value in
      guard
        terms.allSatisfy({
          value.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        })
      else { return nil }
      return Option(id: index, value: value)
    }
  }
}

/// Reject oversized prompts instead of truncating permission choices or editable values.
enum ExtensionDialogLimits {
  static let maximumBytes = 256 * 1024
  static let maximumOptions = 4096

  static func accepts(_ dialog: ExtensionDialog) -> Bool {
    var remaining = maximumBytes
    func consume(_ text: String) -> Bool {
      let count = text.utf8.count
      guard count <= remaining else { return false }
      remaining -= count
      return true
    }
    guard consume(dialog.title) else { return false }
    switch dialog.kind {
    case .select(let options):
      return options.count <= maximumOptions && options.allSatisfy(consume)
    case .confirm(let message):
      return consume(message)
    case .input(let initial, let placeholder, _):
      return consume(initial) && consume(placeholder)
    }
  }
}

import Foundation

struct ComposerDraft: Codable {
  let text: String
  let attachments: [PromptAttachment]

  var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
}

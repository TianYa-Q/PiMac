import Foundation

struct ComposerDraft: Codable {
  let text: String
  let attachments: [PromptAttachment]
  var messageContext: T3MessageContext? = nil

  var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
}

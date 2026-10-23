import AppKit
import SwiftUI

/// Split prose at hydrated workspace image links, keeping failed downloads as links.
enum MarkdownReplyImages {
  private static let linkExpression = try? NSRegularExpression(
    pattern: #"(`+)[\s\S]*?\1|!?\[([^\]\n]*)\]\(\s*(<[^>\n]+>|[^\s)]+)(?:\s+\"[^\"]*\")?\s*\)"#)

  static func parts(in text: String, attachments: [PromptAttachment]) -> [MarkdownSection] {
    guard !attachments.isEmpty, let regex = linkExpression else {
      return [.text([.paragraph(text)])]
    }
    // 只有遇到真实的本地图片链接才建索引，避免每段无链接正文都扫描全部附件。
    var images: [String: PromptAttachment]?
    var result: [MarkdownSection] = []
    var cursor = text.startIndex
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard match.range(at: 1).location == NSNotFound,
        let range = Range(match.range, in: text),
        let targetRange = Range(match.range(at: 3), in: text),
        let captionRange = Range(match.range(at: 2), in: text),
        range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)] != "\\",
        let url = URL(
          string: String(text[targetRange]).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        ),
        let path = T3ReplyImageLinks.path(for: url)
      else { continue }
      if images == nil {
        var indexed: [String: PromptAttachment] = [:]
        // 同一路径保留第一个图片，非图片不占用索引，保持原 first(where:) 语义。
        for attachment in attachments where attachment.isImage {
          if let path = attachment.replyImagePath, indexed[path] == nil {
            indexed[path] = attachment
          }
        }
        images = indexed
      }
      guard let attachment = images?[path] else { continue }
      let prefix = String(text[cursor..<range.lowerBound]).trimmingCharacters(
        in: .whitespacesAndNewlines)
      if !prefix.isEmpty { result.append(.text([.paragraph(prefix)])) }
      result.append(.image(attachment, caption: String(text[captionRange])))
      cursor = range.upperBound
    }
    let suffix = String(text[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
    if !suffix.isEmpty { result.append(.text([.paragraph(suffix)])) }
    return result
  }

  static func renderedPaths(in source: String, attachments: [PromptAttachment]) -> Set<String> {
    var paths = Set<String>()
    for block in MarkdownParser.parse(source) {
      guard case .paragraph(let text) = block else { continue }
      for part in parts(in: text, attachments: attachments) {
        if case .image(let attachment, _) = part, let path = attachment.replyImagePath {
          paths.insert(path)
        }
      }
    }
    return paths
  }
}

struct InlineReplyImageView: View {
  let attachment: PromptAttachment
  let caption: String
  @State private var showingPreview = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let image = NSImage(contentsOf: attachment.url) {
        Button {
          showingPreview = true
        } label: {
          Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 480, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("点击查看原图")
        .accessibilityLabel(caption.isEmpty ? "图片" : caption)
      } else {
        Label("图片暂不可用", systemImage: "photo")
          .foregroundStyle(.secondary)
      }
      if !caption.isEmpty {
        Text(caption).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
    }
    .sheet(isPresented: $showingPreview) {
      ImageAttachmentPreview(attachment: attachment)
    }
  }
}

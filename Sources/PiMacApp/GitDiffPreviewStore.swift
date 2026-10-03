import Combine
import CoreFoundation
import Foundation

/// Validated, bounded presentation of untrusted Server diff responses.
struct GitDiffPreview: Equatable {
  let text: String
  let truncated: Bool
  enum InvalidResponse: Error { case malformed }

  static func validated(_ result: [String: Any], maxBytes: Int = 2 * 1024 * 1024) throws
    -> GitDiffPreview
  {
    precondition(maxBytes > 0)
    guard let sources = result["sources"] as? [[String: Any]] else {
      throw InvalidResponse.malformed
    }
    var text = Data()
    var truncated = false
    for source in sources {
      guard let kind = source["kind"] as? String else { throw InvalidResponse.malformed }
      guard kind == "working-tree" else { continue }
      guard let diff = source["diff"] as? String,
        let flag = source["truncated"] as? NSNumber,
        CFGetTypeID(flag) == CFBooleanGetTypeID()
      else { throw InvalidResponse.malformed }
      truncated = truncated || flag.boolValue
      if !text.isEmpty && !diff.isEmpty {
        if text.count < maxBytes { text.append(0x0A) } else { truncated = true }
      }
      let available = maxBytes - text.count
      let bytes = diff.utf8
      if bytes.count > available { truncated = true }
      text.append(contentsOf: bytes.prefix(available))
    }
    // A byte limit may split a multibyte character. Trim that final fragment only.
    while !text.isEmpty && String(data: text, encoding: .utf8) == nil { text.removeLast() }
    return GitDiffPreview(text: String(decoding: text, as: UTF8.self), truncated: truncated)
  }
}

@MainActor
final class GitDiffPreviewStore: ObservableObject {
  @Published private(set) var preview: GitDiffPreview?
  @Published private(set) var loading = false
  @Published private(set) var failed = false
  private var requestID = UUID()

  func load(rpc: () async throws -> [String: Any]) async {
    let current = UUID()
    requestID = current
    preview = nil
    loading = true
    failed = false
    defer { if requestID == current { loading = false } }
    do {
      let result = try await rpc()
      try Task.checkCancellation()
      guard requestID == current else { return }
      preview = try GitDiffPreview.validated(result)
    } catch {
      guard requestID == current else { return }
      if !(error is CancellationError) && !Task.isCancelled { failed = true }
    }
  }
}

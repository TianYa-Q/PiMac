import Foundation

struct SessionSearchResult: Identifiable, Sendable {
  let session: SessionItem
  let snippet: String?

  var id: String { session.path }
}

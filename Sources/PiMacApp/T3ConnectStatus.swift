import Foundation

struct T3ConnectStatus: Decodable, Equatable {
  let available: Bool
  let enabled: Bool
  let linked: Bool
  let authorized: Bool?
  let networkDiagnostic: String?
  let loginPending: Bool
  let busy: Bool
  let account: String
  let tunnelStatus: String?
  let tunnelURL: String?
  let backend: String?
  let deviceCount: Int?
  let message: String
  let requests: Int
  let accepted: Int
  let queuedDeliveries: Int
  let successfulDeliveries: Int
  let failedDeliveries: Int
}

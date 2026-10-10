import Darwin
import Foundation
import Security

struct T3NetworkEndpoint: Equatable {
  let host: String
  let port: Int

  init(host: String, port: Int) throws {
    guard (host == "0.0.0.0" || Self.isPrivateIPv4(host)), (1024...65535).contains(port) else {
      throw T3BridgeService.ServiceError.invalidEndpoint
    }
    self.host = host
    self.port = port
  }

  /// Wildcard is a bind address, never a client connection address.
  func connectionURL(interfaces: [Interface] = Self.interfaces()) -> URL? {
    let address: String
    if host == "0.0.0.0" {
      guard let preferred = interfaces.first(where: { $0.name == "en0" })
        ?? interfaces.first(where: { $0.name.hasPrefix("en") }) ?? interfaces.first
      else { return nil }
      address = preferred.address
    } else {
      address = host
    }
    return URL(string: "http://\(address):\(port)")
  }

  static func isPrivateIPv4(_ host: String) -> Bool {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    let numbers = parts.compactMap { Int($0) }
    guard numbers.count == 4,
      zip(parts, numbers).allSatisfy({ String($0.1) == $0.0 && (0...255).contains($0.1) })
    else { return false }
    let a = numbers[0]
    let b = numbers[1]
    return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
  }

  struct Interface: Identifiable {
    let name: String
    let address: String
    var id: String { "\(name):\(address)" }
  }

  static func interfaces() -> [Interface] {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0, let first else { return [] }
    defer { freeifaddrs(first) }
    var result: [Interface] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let item = cursor {
      defer { cursor = item.pointee.ifa_next }
      guard item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
        let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
      else { continue }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          address, socklen_t(address.pointee.sa_len), &buffer,
          socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
      else { continue }
      let host = String(cString: buffer)
      if isPrivateIPv4(host) {
        result.append(Interface(name: String(cString: item.pointee.ifa_name), address: host))
      }
    }
    return result.sorted { $0.id < $1.id }
  }

  static func secret() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = bytes.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
    }
    guard status == errSecSuccess else { throw T3BridgeService.ServiceError.randomUnavailable }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }
}

/// LAN defaults on; persist only endpoint and explicit disable, never credentials.
struct T3ConnectionPreferences {
  static let key = "t3RememberedLANEndpointV2"
  static let enabledKey = "t3LANEnabled"

  static func isEnabled(in defaults: UserDefaults) -> Bool {
    defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
  }

  static func startupEndpoint(from defaults: UserDefaults) -> T3NetworkEndpoint? {
    guard isEnabled(in: defaults) else { return nil }
    // Keep the remembered port, but never bind to a remembered IP. Start even
    // while offline so newly connected networks work without a service restart.
    return try? T3NetworkEndpoint(host: "0.0.0.0", port: load(from: defaults)?.port ?? 3773)
  }
  private struct Endpoint: Codable {
    let host: String
    let port: Int
  }

  static func load(from defaults: UserDefaults) -> T3NetworkEndpoint? {
    guard let data = defaults.data(forKey: key),
      let saved = try? JSONDecoder().decode(Endpoint.self, from: data),
      let endpoint = try? T3NetworkEndpoint(host: saved.host, port: saved.port)
    else { return nil }
    return endpoint
  }

  static func save(_ endpoint: T3NetworkEndpoint?, to defaults: UserDefaults) {
    guard let endpoint else {
      defaults.removeObject(forKey: key)
      return
    }
    let data = try? JSONEncoder().encode(Endpoint(host: endpoint.host, port: endpoint.port))
    defaults.set(data, forKey: key)
  }
}

struct T3Pairing: Decodable {
  let id: String
  let credential: String
  let expiresAt: String
  var expiry: Date? {
    ISO8601DateFormatter.t3.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
  }

  func isValid(at now: Date) -> Bool {
    guard !credential.isEmpty, let expiry else { return false }
    return expiry > now
  }

  func url(base: URL) -> URL {
    var parts = URLComponents(
      url: base.appendingPathComponent("pair"), resolvingAgainstBaseURL: false)!
    parts.fragment = "token=\(credential)"
    return parts.url!
  }
}

struct T3PairedClient: Decodable, Identifiable, Equatable {
  struct Metadata: Decodable, Equatable {
    let label: String?
    let deviceType: String
    let os: String?
  }
  let sessionId: String
  let client: Metadata
  let connected: Bool
  let expiresAt: String
  var id: String { sessionId }
  var name: String { client.label ?? client.os ?? "T3 设备" }
}

extension ISO8601DateFormatter {
  fileprivate static var t3: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }
}

import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3ConnectionModelsTests {
  @Test func privateAddressesAreCanonicalAndPublicOrWildcardAddressesAreRejected() throws {
    for host in [
      "10.0.0.1", "172.16.1.2", "172.31.1.2", "192.168.1.7",
    ] {
      #expect(try T3NetworkEndpoint(host: host, port: 3773).host == host)
    }
    for host in [
      "0.0.0.0", "127.0.0.1", "8.8.8.8", "172.32.1.1", "100.63.1.1", "100.64.0.1", "100.127.255.1",
      "100.128.1.1", "192.168.01.2",
      "::1", "localhost", "192.168.1.999", "192.168.1.2/24", "192.168.1.2 ",
    ] {
      #expect(throws: T3BridgeService.ServiceError.self) {
        _ = try T3NetworkEndpoint(host: host, port: 3773)
      }
    }
    for port in [0, 1023, 65536] {
      #expect(throws: T3BridgeService.ServiceError.self) {
        _ = try T3NetworkEndpoint(host: "192.168.1.2", port: port)
      }
    }
  }

  @Test func discoveredInterfacesOnlyContainEligibleAddresses() {
    #expect(
      T3NetworkEndpoint.interfaces().allSatisfy { T3NetworkEndpoint.isPrivateIPv4($0.address) })
  }

  @Test func supervisorSecretsAreIndependentAndNeverPersistedByTheModel() throws {
    let first = try T3NetworkEndpoint.secret()
    let second = try T3NetworkEndpoint.secret()
    #expect(first != second)
    #expect(first.count == 64 && first.allSatisfy { "0123456789abcdef".contains($0) })
  }

  @Test func pairingLinksKeepSecretsInTheFragmentAndExpiryParses() throws {
    let credential = String(repeating: "ab", count: 32)
    let pairing = T3Pairing(id: "id", credential: credential, expiresAt: "2026-10-02T10:00:00.000Z")
    let url = pairing.url(base: try #require(URL(string: "http://192.168.1.2:3773")))
    #expect(url.path == "/pair")
    #expect(url.query == nil)
    #expect(url.fragment == "token=\(credential)")
    #expect(pairing.expiry != nil)
  }

  @Test func upgradingToTunnelOnlyClearsLegacyLANConsent() throws {
    let suite = "pimac-t3-preferences-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    T3ConnectionPreferences.save(
      try T3NetworkEndpoint(host: "192.168.1.2", port: 3773), to: defaults)
    let service = T3BridgeService(defaults: defaults)
    #expect(T3ConnectionPreferences.load(from: defaults) == nil)
    #expect(defaults.object(forKey: T3ConnectionPreferences.key) == nil)
    #expect(service.serverURL == nil)
    service.stop()
    #expect(service.clients.isEmpty)
    _ = T3BridgeService(defaults: defaults)
    #expect(T3ConnectionPreferences.load(from: defaults) == nil)
  }

}

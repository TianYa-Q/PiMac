import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3ConnectionModelsTests {
  @Test func privateAndWildcardAddressesAreCanonicalAndPublicAddressesAreRejected() throws {
    for host in [
      "0.0.0.0", "10.0.0.1", "172.16.1.2", "172.31.1.2", "192.168.1.7",
    ] {
      #expect(try T3NetworkEndpoint(host: host, port: 3773).host == host)
    }
    for host in [
      "127.0.0.1", "8.8.8.8", "172.32.1.1", "100.63.1.1", "100.64.0.1", "100.127.255.1",
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

  @Test func pairingExpiresAtBoundaryAndRejectsInvalidCredentials() throws {
    let pairing = T3Pairing(id: "id", credential: "fixture", expiresAt: "2026-10-02T10:00:00Z")
    let expiry = try #require(pairing.expiry)
    #expect(pairing.isValid(at: expiry.addingTimeInterval(-1)))
    #expect(!pairing.isValid(at: expiry))
    #expect(!pairing.isValid(at: expiry.addingTimeInterval(1)))
    #expect(
      !T3Pairing(id: "id", credential: "", expiresAt: pairing.expiresAt).isValid(
        at: expiry.addingTimeInterval(-1)))
    #expect(!T3Pairing(id: "id", credential: "fixture", expiresAt: "invalid").isValid(at: expiry))
  }

  @Test func lanDefaultsOnBindsWildcardEvenOfflineAndRemembersDisable() throws {
    let suite = "pimac-lan-defaults-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let interfaces = [
      T3NetworkEndpoint.Interface(name: "utun8", address: "10.0.0.2"),
      T3NetworkEndpoint.Interface(name: "en1", address: "192.168.2.3"),
      T3NetworkEndpoint.Interface(name: "en0", address: "192.168.1.3"),
    ]
    #expect(T3ConnectionPreferences.isEnabled(in: defaults))
    let automatic = T3ConnectionPreferences.startupEndpoint(from: defaults)
    #expect(automatic?.host == "0.0.0.0")
    #expect(automatic?.port == 3773)
    #expect(T3ConnectionPreferences.startupEndpoint(from: defaults) == automatic)
    #expect(automatic?.connectionURL(interfaces: []) == nil)
    #expect(automatic?.connectionURL(interfaces: interfaces)?.host == "192.168.1.3")
    #expect(automatic?.connectionURL(interfaces: [interfaces[1]])?.host == "192.168.2.3")
    T3ConnectionPreferences.save(
      try T3NetworkEndpoint(host: "192.168.2.3", port: 4773), to: defaults)
    #expect(
      T3ConnectionPreferences.startupEndpoint(from: defaults)?.host
        == "0.0.0.0")
    let changedNetwork = T3ConnectionPreferences.startupEndpoint(
      from: defaults)
    #expect(changedNetwork?.host == "0.0.0.0")
    #expect(changedNetwork?.port == 4773)
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    #expect(!T3ConnectionPreferences.isEnabled(in: defaults))
    #expect(T3ConnectionPreferences.startupEndpoint(from: defaults) == nil)
    defaults.set(true, forKey: T3ConnectionPreferences.enabledKey)
    #expect(T3ConnectionPreferences.startupEndpoint(from: defaults) != nil)
  }

  @Test func lanConsentPersistsButLegacyConsentIsNotReinterpreted() throws {
    let suite = "pimac-t3-preferences-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    T3ConnectionPreferences.save(
      try T3NetworkEndpoint(host: "192.168.1.2", port: 3773), to: defaults)
    defaults.set(Data("legacy".utf8), forKey: "t3RememberedNetworkEndpoint")
    let service = T3BridgeService(defaults: defaults)
    #expect(T3ConnectionPreferences.load(from: defaults)?.host == "192.168.1.2")
    #expect(defaults.object(forKey: "t3RememberedNetworkEndpoint") == nil)
    #expect(service.lanEndpoint == nil)
    #expect(service.serverURL == nil)
    service.stop()
    #expect(service.clients.isEmpty)
    #expect(service.lanStateKnown)
    #expect(!service.lanBusy)
    #expect(service.lanPairing == nil)
    _ = T3BridgeService(defaults: defaults)
    #expect(T3ConnectionPreferences.load(from: defaults)?.host == "192.168.1.2")
    T3ConnectionPreferences.save(nil, to: defaults)
    #expect(T3ConnectionPreferences.load(from: defaults) == nil)
  }

}

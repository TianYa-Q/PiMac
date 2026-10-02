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

  @Test func readDiagnosticsSeparateDeliveryFromPairingAndDecodeWithoutCredentials() throws {
    let data = Data(
      #"{"shellHttpRequests":1,"shellHttpStatus":200,"catalogReads":2,"catalogFailures":0,"shellSubscriptions":1,"shellSnapshots":1,"shellCompletionMarkers":1,"lastRPC":"orchestration.subscribeShell","lastFailure":"none"}"#
        .utf8)
    let diagnostics = try JSONDecoder().decode(T3ReadDiagnostics.self, from: data)
    #expect(diagnostics.shellHttpStatus == 200)
    #expect(diagnostics.shellCompletionMarkers == 1)
    #expect(diagnostics.summary.contains("HTTP 列表请求：1"))
    #expect(diagnostics.summary.contains("列表订阅：1"))
    #expect(diagnostics.summary.contains("orchestration.subscribeShell"))
  }

  @Test func confirmedNetworkPreferenceSurvivesShutdownButNotExplicitDisable() throws {
    let suite = "pimac-t3-preferences-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(T3ConnectionPreferences.load(from: defaults) == nil)
    let endpoint = try T3NetworkEndpoint(host: "192.168.1.2", port: 3773)
    T3ConnectionPreferences.save(endpoint, to: defaults)
    let first = T3BridgeService(defaults: defaults)
    #expect(first.rememberedNetwork == endpoint)
    first.stop()  // App shutdown, not an explicit user disable.
    let restarted = T3BridgeService(defaults: defaults)
    #expect(restarted.rememberedNetwork == endpoint)
    #expect(restarted.publicURL == nil)  // Preference alone is not a live listener.
    restarted.disable()
    #expect(T3BridgeService(defaults: defaults).rememberedNetwork == nil)
    #expect(defaults.object(forKey: T3ConnectionPreferences.key) == nil)
  }

  @Test func uncheckingNetworkConsentClearsSavedEndpoint() throws {
    let suite = "pimac-t3-preferences-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    T3ConnectionPreferences.save(
      try T3NetworkEndpoint(host: "10.0.0.1", port: 4321), to: defaults)
    let service = T3BridgeService(defaults: defaults)
    service.forgetNetworkPreference()
    #expect(service.rememberedNetwork == nil)
    #expect(T3ConnectionPreferences.load(from: defaults) == nil)
  }

  @Test func corruptOrIneligibleSavedEndpointsCannotEnableNetworkExposure() throws {
    let suite = "pimac-t3-preferences-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for json in [
      "{bad", #"{"host":"0.0.0.0","port":3773}"#,
      #"{"host":"100.64.0.1","port":3773}"#,
      #"{"host":"192.168.1.2","port":80}"#,
    ] {
      defaults.set(Data(json.utf8), forKey: T3ConnectionPreferences.key)
      #expect(T3BridgeService(defaults: defaults).rememberedNetwork == nil)
    }
  }

  @Test func previewIsOffAndDoesNotInventAPhoneAddress() {
    let service = T3BridgeService()
    #expect(!service.isEnabled)
    #expect(service.publicURL == nil)
    #expect(service.pairing == nil)
    #expect(service.connectionURL == nil)
    service.stop()
    #expect(service.clients.isEmpty)
    #expect(service.readDiagnostics == nil)
  }
}

import Darwin
import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct T3LANServiceTests {
  @Test(.timeLimit(.minutes(1)))
  func failedBindReconcilesAndPairingRequiresConfirmedLiveListener() async throws {
    // No private network is required by CI; the pure transport tests use loopback.
    guard let interface = T3NetworkEndpoint.interfaces().first else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "pimac-lan-service-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(false, forKey: T3ConnectionPreferences.enabledKey)
    let workspace = WorkspaceModel(restoreUserState: false)
    let service = T3BridgeService(defaults: defaults, stateDirectory: root)
    defer {
      service.stop()
      workspace.disconnectAll()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #expect(fd >= 0)
    var socketOpen = true
    defer { if socketOpen { Darwin.close(fd) } }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    #expect(inet_pton(AF_INET, interface.address, &address.sin_addr) == 1)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    #expect(bound == 0)
    #expect(listen(fd, 1) == 0)
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let located = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
    }
    #expect(located == 0)
    let endpoint = try T3NetworkEndpoint(
      host: interface.address, port: Int(UInt16(bigEndian: address.sin_port)))
    try service.start(workspace: workspace, token: T3NetworkEndpoint.secret())
    for _ in 0..<200 where service.serverURL == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    _ = try #require(service.serverURL)
    await service.configureLAN(endpoint)
    #expect(service.lanStateKnown)
    #expect(service.lanEndpoint == nil)
    #expect(!service.lanBusy)
    #expect(service.lanMessage.contains("实际状态"))
    await service.generateLANPairing()
    #expect(service.lanPairing == nil)
    Darwin.close(fd)
    socketOpen = false
    await service.configureLAN(endpoint)
    #expect(service.lanEndpoint == endpoint)
    #expect(T3ConnectionPreferences.load(from: defaults) == endpoint)
    await service.generateLANPairing()
    #expect(service.lanPairing?.isValid(at: Date()) == true)
    await service.refreshLAN()
    #expect(service.lanStateKnown)
    #expect(service.lanEndpoint == endpoint)
    await service.configureLAN(nil)
    #expect(service.lanEndpoint == nil)
    #expect(service.lanPairing == nil)
    #expect(!T3ConnectionPreferences.isEnabled(in: defaults))
    await service.revokeClient(UUID().uuidString.lowercased())
    #expect(service.managementMessage.contains("已不存在"))
    #expect(await service.stopAndWait())
  }
}

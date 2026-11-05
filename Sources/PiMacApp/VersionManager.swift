import Foundation

struct ManagedExtension: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case npm(name: String, pinned: Bool)
    case local
  }
  let source: String
  let path: String
  let scope: String
  let kind: Kind
  var currentVersion: String?
  var latestVersion: String?
  var error: String?
  var id: String { source }
  var hasUpdate: Bool {
    guard let currentVersion, let latestVersion else { return false }
    return VersionManagerModel.isNewer(latestVersion, than: currentVersion)
  }
}

/// 安装清单由内部发布脚本生成；这里核对实际文件，不把锁定版本当成已安装版本。
struct ManagedPiRuntime: Decodable, Sendable {
  struct Module: Decodable, Sendable {
    let name: String
    let version: String
    let manifestPath: String
  }
  let schemaVersion: Int
  let executable: String
  let modules: [Module]

  static var manifestURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/PiMac/ManagedRuntime/modules.json")
  }

  static func load(from url: URL = manifestURL) throws -> ManagedPiRuntime {
    let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    guard value.schemaVersion == 1, !value.modules.isEmpty,
      value.modules.contains(where: { $0.name == "@earendil-works/pi-coding-agent" }),
      Set(value.modules.map(\.name)).count == value.modules.count,
      FileManager.default.isExecutableFile(atPath: value.executable)
    else { throw InventoryError.invalid }
    for module in value.modules {
      let data = try Data(contentsOf: URL(fileURLWithPath: module.manifestPath))
      let manifest = try JSONDecoder().decode(PackageVersion.self, from: data)
      guard manifest.version == module.version else {
        throw InventoryError.versionMismatch(module.name)
      }
    }
    return value
  }

  private struct PackageVersion: Decodable { let version: String }
  enum InventoryError: LocalizedError {
    case invalid
    case versionMismatch(String)
    var errorDescription: String? {
      switch self {
      case .invalid: "内部模块清单无效或运行文件缺失，请由 PiMac 重新部署。"
      case .versionMismatch(let name): "\(name) 的实际版本与内部清单不一致，请由 PiMac 重新部署。"
      }
    }
  }
}

@MainActor
final class VersionManagerModel: ObservableObject {
  @Published private(set) var piCurrentVersion: String?
  @Published private(set) var piLatestVersion: String?
  @Published private(set) var extensions: [ManagedExtension] = []
  @Published private(set) var isChecking = false
  @Published private(set) var message = ""
  private let checksEnabled: Bool
  private let manifestURL: URL

  init(manifestURL: URL = ManagedPiRuntime.manifestURL) {
    self.manifestURL = manifestURL
    checksEnabled = true
  }

  init(current: String, latest: String, extensions: [ManagedExtension]) {
    manifestURL = ManagedPiRuntime.manifestURL
    checksEnabled = false
    piCurrentVersion = current
    piLatestVersion = latest
    self.extensions = extensions
  }

  var piHasUpdate: Bool {
    guard let current = piCurrentVersion, let latest = piLatestVersion else { return false }
    return Self.isNewer(latest, than: current)
  }

  func refresh() {
    guard checksEnabled, !isChecking else { return }
    isChecking = true
    message = ""
    let url = manifestURL
    Task {
      defer { isChecking = false }
      do {
        let inventory = try await Task.detached { try ManagedPiRuntime.load(from: url) }.value
        var rows: [ManagedExtension] = []
        for module in inventory.modules {
          var row = ManagedExtension(
            source: module.name, path: module.manifestPath, scope: "内部管理",
            kind: module.name.hasPrefix("PiMac") || module.name == "账户管理"
              ? .local : .npm(name: module.name, pinned: true), currentVersion: module.version)
          switch row.kind {
          case .local:
            // 自有模块没有 Registry 发布；最新即当前随 PiMac 管理的版本。
            row.latestVersion = module.version
          case .npm(let name, _):
            do { row.latestVersion = try await Self.latestNPMVersion(package: name) } catch {
              row.error = "最新版本检查失败：\(error.localizedDescription)"
            }
          }
          rows.append(row)
        }
        let core = rows.first { $0.source == "@earendil-works/pi-coding-agent" }
        piCurrentVersion = core?.currentVersion
        piLatestVersion = core?.latestVersion
        extensions = rows.filter { $0.source != "@earendil-works/pi-coding-agent" }
        if let error = core?.error { message = error }
      } catch {
        // 读取失败保留最后成功快照，明确标记失败，不能伪装成“暂无模块”。
        message = "内部模块读取失败：\(error.localizedDescription)"
      }
    }
  }

  nonisolated static func latestNPMVersion(package name: String) async throws -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed),
      let url = URL(string: "https://registry.npmjs.org/\(encoded)/latest")
    else { throw URLError(.badURL) }
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw URLError(.badServerResponse)
    }
    struct Version: Decodable { let version: String }
    let version = try JSONDecoder().decode(Version.self, from: data).version
    guard !version.isEmpty else { throw URLError(.cannotParseResponse) }
    return version
  }

  nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
    candidate.compare(current, options: .numeric) == .orderedDescending
  }
}

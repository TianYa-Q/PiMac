import Foundation

struct ManagedExtension: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case npm(name: String, pinned: Bool)
    case git(pinned: Bool)
    case local
  }

  let source: String
  let path: String
  let scope: String
  let kind: Kind
  var currentVersion: String?
  var latestVersion: String?
  var error: String?

  var id: String { "\(scope):\(source)" }

  var hasUpdate: Bool {
    guard !isPinned, let currentVersion, let latestVersion else { return false }
    if case .git = kind { return latestVersion != currentVersion }
    return VersionManagerModel.isNewer(latestVersion, than: currentVersion)
  }

  var isPinned: Bool {
    switch kind {
    case .npm(_, let pinned), .git(let pinned): pinned
    case .local: false
    }
  }

  var canUpdate: Bool {
    switch kind {
    case .local: false
    case .npm, .git: !isPinned
    }
  }
}

@MainActor
final class VersionManagerModel: ObservableObject {
  @Published private(set) var piCurrentVersion: String?
  @Published private(set) var piLatestVersion: String?
  @Published private(set) var extensions: [ManagedExtension] = []
  @Published private(set) var isChecking = false
  @Published private(set) var updatingID: String?
  @Published private(set) var message = ""

  private var piPath: String
  private var projectURL: URL?

  init(piPath: String, projectURL: URL?) {
    self.piPath = piPath
    self.projectURL = projectURL
  }

  var piHasUpdate: Bool {
    guard let current = piCurrentVersion, let latest = piLatestVersion else { return false }
    return Self.isNewer(latest, than: current)
  }

  var extensionUpdateCount: Int { extensions.filter(\.hasUpdate).count }

  func configure(piPath: String, projectURL: URL?) {
    self.piPath = piPath
    self.projectURL = projectURL
  }

  func refresh() {
    guard !isChecking, updatingID == nil else { return }
    isChecking = true
    message = ""
    let path = piPath
    let cwd = projectURL
    Task {
      let snapshot = await Self.loadSnapshot(piPath: path, projectURL: cwd)
      piCurrentVersion = snapshot.piCurrent
      piLatestVersion = snapshot.piLatest
      extensions = snapshot.extensions
      message = snapshot.message
      isChecking = false
    }
  }

  func updatePi() {
    runUpdate(id: "pi", arguments: ["update", "--self"])
  }

  func updateAllExtensions() {
    runUpdate(id: "extensions", arguments: ["update", "--extensions"])
  }

  func update(_ item: ManagedExtension) {
    guard item.canUpdate else { return }
    runUpdate(id: item.id, arguments: ["update", "--extension", item.source])
  }

  private func runUpdate(id: String, arguments: [String]) {
    guard updatingID == nil, !isChecking else { return }
    updatingID = id
    message = "正在更新…"
    let path = piPath
    let cwd = projectURL
    Task {
      let result = await Task.detached {
        Self.run(path, arguments: arguments, workingDirectory: cwd)
      }.value
      if result.status == 0 {
        message = result.output.isEmpty ? "更新完成。重新打开会话后即可使用新版本。" : result.output
        updatingID = nil
        refresh()
      } else {
        message = result.output.isEmpty ? "更新失败（状态码 \(result.status)）。" : result.output
        updatingID = nil
      }
    }
  }

  private struct Snapshot: Sendable {
    let piCurrent: String?
    let piLatest: String?
    let extensions: [ManagedExtension]
    let message: String
  }

  nonisolated private static func loadSnapshot(
    piPath: String, projectURL: URL?
  ) async -> Snapshot {
    let versionResult = await Task.detached {
      run(piPath, arguments: ["--version"], workingDirectory: projectURL)
    }.value
    let current =
      versionResult.status == 0
      ? versionResult.output.split(whereSeparator: \.isWhitespace).first.map(String.init) : nil

    var latest: String?
    var checkMessage = ""
    if current != nil,
      let url = URL(string: "https://pi.dev/api/latest-version")
    {
      do {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 200,
          let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
          latest = payload["version"] as? String
        }
      } catch {
        checkMessage = "无法检查 Pi 最新版本：\(error.localizedDescription)"
      }
    } else if versionResult.status != 0 {
      checkMessage = versionResult.output.isEmpty ? "无法运行 Pi。" : versionResult.output
    }

    let listResult = await Task.detached {
      run(piPath, arguments: ["list", "--approve"], workingDirectory: projectURL)
    }.value
    var packages = parsePackageList(listResult.output)
    for index in packages.indices {
      packages[index].currentVersion = installedVersion(for: packages[index])
      switch packages[index].kind {
      case .npm(let name, _):
        do {
          packages[index].latestVersion = try await latestNPMVersion(package: name)
        } catch {
          packages[index].error = error.localizedDescription
        }
      case .git(let pinned):
        guard !pinned else { continue }
        let remote = await Task.detached {
          runGitRemoteVersion(at: packages[index].path)
        }.value
        packages[index].latestVersion = remote.version
        packages[index].error = remote.error
      case .local:
        break
      }
    }
    if listResult.status != 0, checkMessage.isEmpty {
      checkMessage = listResult.output.isEmpty ? "无法读取扩展包列表。" : listResult.output
    }
    return Snapshot(
      piCurrent: current,
      piLatest: latest,
      extensions: packages,
      message: checkMessage
    )
  }

  nonisolated static func parsePackageList(_ output: String) -> [ManagedExtension] {
    var scope = "用户"
    var pendingSource: String?
    var result: [ManagedExtension] = []
    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
      let raw = String(rawLine)
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("User packages:") {
        scope = "用户"
        pendingSource = nil
      } else if line.hasPrefix("Project packages:") {
        scope = "项目"
        pendingSource = nil
      } else if raw.hasPrefix("  "), !raw.hasPrefix("    "), !line.isEmpty {
        pendingSource = line
      } else if raw.hasPrefix("    "), let source = pendingSource, !line.isEmpty {
        result.append(
          ManagedExtension(
            source: source,
            path: line,
            scope: scope,
            kind: packageKind(for: source),
            currentVersion: nil,
            latestVersion: nil,
            error: nil
          ))
        pendingSource = nil
      }
    }
    return result
  }

  nonisolated private static func packageKind(for source: String) -> ManagedExtension.Kind {
    if source.hasPrefix("npm:") {
      let spec = String(source.dropFirst(4))
      let separator = spec.lastIndex(of: "@")
      let hasPinnedVersion = separator.map { $0 != spec.startIndex } ?? false
      let name = hasPinnedVersion ? String(spec[..<separator!]) : spec
      return .npm(name: name, pinned: hasPinnedVersion)
    }
    if source.hasPrefix("git:") || source.hasPrefix("http://")
      || source.hasPrefix("https://") || source.hasPrefix("ssh://")
    {
      // A ref follows the last @. The @ in git@host is before the repository path.
      let tail = source.split(separator: "/").last.map(String.init) ?? source
      return .git(pinned: tail.contains("@"))
    }
    return .local
  }

  nonisolated private static func installedVersion(for item: ManagedExtension) -> String? {
    if case .git = item.kind {
      let result = run(
        "/usr/bin/git",
        arguments: ["-C", item.path, "rev-parse", "--short", "HEAD"]
      )
      if result.status == 0 { return result.output }
    }
    let url = URL(fileURLWithPath: item.path).appendingPathComponent("package.json")
    if let data = try? Data(contentsOf: url),
      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = payload["version"] as? String
    {
      return version
    }
    return nil
  }

  nonisolated private static func latestNPMVersion(package name: String) async throws -> String? {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed),
      let url = URL(string: "https://registry.npmjs.org/\(encoded)/latest")
    else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return payload["version"] as? String
  }

  nonisolated private static func runGitRemoteVersion(
    at path: String
  ) -> (version: String?, error: String?) {
    let result = run(
      "/usr/bin/git", arguments: ["-C", path, "ls-remote", "origin", "HEAD"])
    guard result.status == 0 else { return (nil, result.output) }
    let hash = result.output.split(whereSeparator: \.isWhitespace).first.map(String.init)
    return (hash.map { String($0.prefix(7)) }, nil)
  }

  nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
    let left = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
      .split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    let right = current.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
      .split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    if left != right {
      for index in 0..<max(left.count, right.count) {
        let lhs = index < left.count ? left[index] : 0
        let rhs = index < right.count ? right[index] : 0
        if lhs != rhs { return lhs > rhs }
      }
    }
    return candidate != current && !candidate.allSatisfy(\.isHexDigit)
  }

  nonisolated private static func run(
    _ executable: String, arguments: [String], workingDirectory: URL? = nil
  ) -> (status: Int32, output: String) {
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pi-mac-version-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
    guard let outputHandle = try? FileHandle(forWritingTo: temporaryURL) else {
      return (-1, "无法创建命令输出文件。")
    }
    defer {
      try? outputHandle.close()
      try? FileManager.default.removeItem(at: temporaryURL)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", "exec \"$@\"", "pi-mac-version", executable] + arguments
    process.currentDirectoryURL = workingDirectory
    process.standardOutput = outputHandle
    process.standardError = outputHandle
    do {
      try process.run()
      process.waitUntilExit()
      try? outputHandle.synchronize()
      let data = (try? Data(contentsOf: temporaryURL)) ?? Data()
      let output = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return (process.terminationStatus, output)
    } catch {
      return (-1, error.localizedDescription)
    }
  }
}

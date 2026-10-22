import AppKit
import Foundation

/// 这里只管理 Pi 的标准文件位置，不把磁盘清单当成会话已加载的资源清单。
struct PiResourceStore {
  enum Scope: String, CaseIterable, Identifiable {
    case global = "全局"
    case project = "当前项目"
    var id: Self { self }
  }

  enum Kind {
    case instructions
    case skill
  }

  enum SkillLocation: String, CaseIterable, Identifiable {
    case pi = "Pi 目录"
    case agents = ".agents 目录"
    var id: Self { self }
  }

  struct Entry: Identifiable {
    let url: URL
    let kind: Kind
    let removalURL: URL
    var id: URL { url }
    var title: String {
      kind == .instructions
        ? url.lastPathComponent
        : (url.lastPathComponent == "SKILL.md"
          ? url.deletingLastPathComponent().lastPathComponent
          : url.deletingPathExtension().lastPathComponent)
    }
  }

  struct Document: Identifiable {
    let entry: Entry
    let original: Data?
    let text: String
    let resolvedURL: URL
    var id: URL { entry.url }

    init(entry: Entry, original: Data?, text: String) {
      self.entry = entry
      self.original = original
      self.text = text
      resolvedURL = entry.url.resolvingSymlinksInPath().standardizedFileURL
    }
  }

  enum StoreError: LocalizedError {
    case invalidName
    case invalidText(URL)
    case changed
    case exists(URL)
    case projectRequired
    case invalidSkill
    case recursiveImport

    var errorDescription: String? {
      switch self {
      case .invalidName:
        return "名称需为 1–64 位小写字母、数字或单连字符，不能以连字符开头或结尾。"
      case .invalidText(let url): return "无法编辑 \(url.path)：文件不是 UTF-8 文本。"
      case .changed: return "文件已被外部修改或删除。请关闭编辑器并刷新后重试，未覆盖磁盘内容。"
      case .exists(let url): return "目标已存在，未覆盖：\(url.path)"
      case .projectRequired: return "请先选择一个项目。"
      case .invalidSkill: return "请选择包含 SKILL.md 的 Skill 文件夹。"
      case .recursiveImport: return "不能把 Skill 导入到它自身或其子目录。"
      }
    }
  }

  let agentDirectory: URL
  let projectURL: URL?
  let homeDirectory: URL
  private let files = FileManager.default

  static var defaultAgentDirectory: URL {
    let override = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"]
    if let override, !override.isEmpty {
      return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
  }

  private func directory(for scope: Scope) throws -> URL {
    switch scope {
    case .global: return agentDirectory
    case .project:
      guard let projectURL else { throw StoreError.projectRequired }
      return projectURL.appendingPathComponent(".pi", isDirectory: true)
    }
  }

  func instructions(for scope: Scope) throws -> Entry {
    let base: URL
    switch scope {
    case .global: base = agentDirectory
    case .project:
      guard let projectURL else { throw StoreError.projectRequired }
      base = projectURL
    }
    let url = base.appendingPathComponent("AGENTS.md")
    return Entry(url: url, kind: .instructions, removalURL: url)
  }

  func skillsDirectory(for scope: Scope, location: SkillLocation = .pi) throws -> URL {
    if location == .pi {
      return try directory(for: scope).appendingPathComponent("skills", isDirectory: true)
    }
    let base: URL
    switch scope {
    case .global: base = homeDirectory
    case .project:
      guard let projectURL else { throw StoreError.projectRequired }
      base = projectURL
    }
    return base.appendingPathComponent(".agents/skills", isDirectory: true)
  }

  func skills(for scope: Scope) throws -> [Entry] {
    var visited = Set<URL>()
    var entries: [Entry] = []

    // 按实际路径去重，既支持链接的 Skill，也避免循环符号链接导致无限遍历。
    func scan(_ directory: URL, isRoot: Bool) throws {
      let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
      guard visited.insert(resolvedDirectory).inserted else {
        return
      }
      let children: [URL]
      do {
        children = try files.contentsOfDirectory(
          at: resolvedDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
          options: [.skipsHiddenFiles]
        )
        .map { directory.appendingPathComponent($0.lastPathComponent) }
      } catch {
        if isRoot && Self.isMissing(error) { return }
        throw error
      }
      let skill = directory.appendingPathComponent("SKILL.md")
      if children.contains(skill),
        try skill.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
          .isRegularFile == true
      {
        entries.append(Entry(url: skill, kind: .skill, removalURL: isRoot ? skill : directory))
        return
      }
      for child in children.sorted(by: { $0.path < $1.path })
      where child.lastPathComponent != "node_modules" {
        let values = try child.resolvingSymlinksInPath()
          .resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true {
          try scan(child, isRoot: false)
        } else if isRoot, values.isRegularFile == true, child.pathExtension == "md" {
          entries.append(Entry(url: child, kind: .skill, removalURL: child))
        }
      }
    }
    for location in SkillLocation.allCases {
      try scan(skillsDirectory(for: scope, location: location), isRoot: true)
    }
    return entries.sorted { $0.url.path < $1.url.path }
  }

  func read(_ entry: Entry) throws -> Document {
    let data = try contents(at: entry.url)
    guard let data else {
      if entry.kind == .skill { throw StoreError.changed }
      return Document(entry: entry, original: nil, text: "")
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw StoreError.invalidText(entry.url)
    }
    return Document(entry: entry, original: data, text: text)
  }

  func newSkill(named name: String, scope: Scope, location: SkillLocation = .pi) throws -> Document
  {
    guard name.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil,
      name.count <= 64
    else { throw StoreError.invalidName }
    let folder = try skillsDirectory(for: scope, location: location)
      .appendingPathComponent(name, isDirectory: true)
    if files.fileExists(atPath: folder.path) { throw StoreError.exists(folder) }
    let entry = Entry(
      url: folder.appendingPathComponent("SKILL.md"), kind: .skill, removalURL: folder)
    return Document(
      entry: entry, original: nil,
      text: "---\nname: \(name)\ndescription: 请说明此 Skill 的用途及适用场景。\n---\n\n# \(name)\n\n请在此编写指令。\n")
  }

  func save(_ document: Document, text: String) throws {
    // 原始字节参与比较，空文件和不存在的文件是不同状态；不静默覆盖外部编辑。
    guard document.entry.url.resolvingSymlinksInPath().standardizedFileURL == document.resolvedURL,
      try contents(at: document.entry.url) == document.original
    else {
      throw StoreError.changed
    }
    let parent = document.entry.url.deletingLastPathComponent()
    if document.original == nil, document.entry.kind == .skill,
      files.fileExists(atPath: parent.path)
    {
      throw StoreError.exists(parent)
    }
    try files.createDirectory(at: parent, withIntermediateDirectories: true)
    let data = Data(text.utf8)
    // 原子写入实际文件，保留 SKILL.md / AGENTS.md 自身的符号链接。
    try data.write(
      to: document.resolvedURL,
      options: document.original == nil ? [.withoutOverwriting] : [.atomic])
  }

  func importSkill(from source: URL, scope: Scope, location: SkillLocation = .pi) throws {
    var isDirectory: ObjCBool = false
    guard files.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue,
      try contents(at: source.appendingPathComponent("SKILL.md")) != nil
    else { throw StoreError.invalidSkill }
    _ = try read(
      Entry(
        url: source.appendingPathComponent("SKILL.md"), kind: .skill, removalURL: source))
    let root = try skillsDirectory(for: scope, location: location)
    let destination = root.appendingPathComponent(source.lastPathComponent, isDirectory: true)
    let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL.path
    let canonicalDestination = destination.resolvingSymlinksInPath().standardizedFileURL.path
    guard canonicalDestination != canonicalSource,
      !canonicalDestination.hasPrefix(canonicalSource + "/")
    else { throw StoreError.recursiveImport }
    if files.fileExists(atPath: destination.path) { throw StoreError.exists(destination) }
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    // 先复制到 Pi 不扫描的隐藏目录，再在同一文件系统内发布，避免失败时加载半份 Skill。
    let staging = root.appendingPathComponent(".pimac-import-\(UUID().uuidString)")
    defer {
      if files.fileExists(atPath: staging.path) {
        try? files.trashItem(at: staging, resultingItemURL: nil)
      }
    }
    try files.copyItem(at: source, to: staging)
    try files.moveItem(at: staging, to: destination)
  }

  func trash(_ document: Document) throws {
    guard document.original != nil,
      document.entry.url.resolvingSymlinksInPath().standardizedFileURL == document.resolvedURL,
      try contents(at: document.entry.url) == document.original
    else { throw StoreError.changed }
    try files.trashItem(at: document.entry.removalURL, resultingItemURL: nil)
  }

  private func contents(at url: URL) throws -> Data? {
    do {
      return try Data(contentsOf: url)
    } catch {
      if Self.isMissing(error) { return nil }
      throw error
    }
  }

  private static func isMissing(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == NSCocoaErrorDomain
      && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
  }
}

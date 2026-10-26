import Darwin
import Foundation

struct TemporaryCleanupWorkspace: Sendable {
  let name: String
  let directory: URL
}

struct TemporaryCleanupResult: Codable, Identifiable, Sendable {
  var id: String { path }
  let name: String
  let path: String
  var moved = 0
  var bytes: Int64 = 0
  var retained = 0
  var message = ""
  var errors: [String] = []
  var items: [String] = []
  // 旧记录没有完成时间；跳过或失败不标记为完整检查。
  var completedAt: Date?
}

/// 只整理已登记工作区的 tmp 直接子项；绝不递归删除，也不清空废纸篓。
actor TemporaryFileCleaner {
  static let retention: TimeInterval = 3 * 24 * 60 * 60
  private let manager = FileManager.default
  private let moveToTrash: @Sendable (URL) throws -> Void
  private let scanBudget: TimeInterval
  private let itemScanBudget: TimeInterval
  private let itemLimit: Int
  private var resumeAfter: [String: String] = [:]

  init(
    scanBudget: TimeInterval = 120, itemScanBudget: TimeInterval = 2,
    itemLimit: Int = 100_000,
    moveToTrash: @escaping @Sendable (URL) throws -> Void = { url in
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
  ) {
    self.moveToTrash = moveToTrash
    self.scanBudget = scanBudget
    self.itemScanBudget = itemScanBudget
    self.itemLimit = itemLimit
  }

  private struct Facts: Equatable {
    var newest: Date = .distantPast
    var bytes: Int64 = 0
    var count = 0
    var inode: UInt64 = 0
    var preserved = false
  }

  enum CleanupError: LocalizedError {
    case unsafePath, scanLimit
    case commandFailed(String)
    var errorDescription: String? {
      switch self {
      case .unsafePath: return "路径或文件类型变化，已停止清理"
      case .scanLimit: return "达到扫描时间或数量上限，剩余内容保留到下次检查"
      case .commandFailed(let name): return "无法确认\(name)，未清理相关内容"
      }
    }
  }

  func clean(
    _ workspaces: [TemporaryCleanupWorkspace], now: Date,
    protection: @escaping @Sendable (URL) async -> String?
  ) async -> [TemporaryCleanupResult] {
    var results: [TemporaryCleanupResult] = []
    for workspace in workspaces {
      var result = TemporaryCleanupResult(name: workspace.name, path: workspace.directory.path)
      do {
        if let reason = await protection(workspace.directory) {
          result.message = reason
          results.append(result)
          continue
        }
        let root = workspace.directory.standardizedFileURL.resolvingSymlinksInPath()
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        guard manager.fileExists(atPath: tmp.path) else {
          result.message = "没有临时目录"
          result.completedAt = Date()
          results.append(result)
          continue
        }
        try validate(root: root, tmp: tmp)
        let cutoff = now.addingTimeInterval(-Self.retention)
        let deadline = Date().addingTimeInterval(scanBudget)
        let tracked = try trackedPaths(root: root)
        let children = try manager.contentsOfDirectory(
          at: tmp, includingPropertiesForKeys: nil)
        if manager.fileExists(atPath: tmp.appendingPathComponent(".keep").path) {
          result.retained = children.count
          result.message = "tmp/.keep 已保留整个临时目录"
          result.completedAt = Date()
          results.append(result)
          continue
        }
        // 独立限制大目录耗时；全局预算耗尽后从下一项继续，避免每轮卡在同一目录。
        let sorted = children.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let start =
          resumeAfter[root.path].flatMap { name in
            sorted.firstIndex { $0.lastPathComponent > name }
          } ?? 0
        let ordered = Array(sorted.dropFirst(start)) + Array(sorted.prefix(start))
        var allChecked = true
        for child in ordered {
          try Task.checkCancellation()
          guard Date() < deadline else {
            allChecked = false
            if result.errors.count < 5 {
              result.errors.append(CleanupError.scanLimit.localizedDescription)
            }
            break
          }
          resumeAfter[root.path] = child.lastPathComponent
          do {
            let first = try facts(
              child, cutoff: cutoff,
              deadline: min(deadline, Date().addingTimeInterval(itemScanBudget)))
            if first.preserved || first.newest >= cutoff
              || tracked.contains(where: { Self.contains(child, $0) })
            {
              result.retained += 1
              continue
            }
            if let reason = await protection(workspace.directory) {
              result.message = reason
              allChecked = false
              break
            }
            // 每次移动前重新读取进程与文件状态，避免扫描后启动的任务和新写入被误清。
            let references = try liveReferences()
            let relative = "tmp/" + child.lastPathComponent
            if references.contains(child.path) || references.contains(relative) {
              result.retained += 1
              continue
            }
            try validate(root: root, tmp: tmp)
            guard try trackedPaths(root: root).allSatisfy({ !Self.contains(child, $0) }) else {
              result.retained += 1
              continue
            }
            let second = try facts(
              child, cutoff: cutoff,
              deadline: min(deadline, Date().addingTimeInterval(itemScanBudget)))
            guard first == second, second.newest < cutoff, !second.preserved else {
              result.retained += 1
              continue
            }
            if let reason = await protection(workspace.directory) {
              result.message = reason
              allChecked = false
              break
            }
            // 主线程保护检查期间也可能切换目录；回到文件执行器后再次确认边界与身份。
            try validate(root: root, tmp: tmp)
            let current = try manager.attributesOfItem(atPath: child.path)
            guard (current[.systemFileNumber] as? NSNumber)?.uint64Value == second.inode,
              current[.type] as? FileAttributeType != .typeSymbolicLink
            else { throw CleanupError.unsafePath }
            try moveToTrash(child)
            result.moved += 1
            result.bytes += second.bytes
            if result.items.count < 30 { result.items.append(child.lastPathComponent) }
          } catch {
            if result.errors.count < 5 {
              result.errors.append("\(child.lastPathComponent)：\(error.localizedDescription)")
            }
            if Date() >= deadline {
              allChecked = false
              break
            }
          }
          await Task.yield()
        }
        result.retained = max(result.retained, children.count - result.moved)
        if allChecked && result.errors.isEmpty { result.completedAt = Date() }
        if result.message.isEmpty { result.message = result.errors.isEmpty ? "检查完成" : "部分内容未整理" }
      } catch {
        result.message = "检查未完成"
        result.errors.append(error.localizedDescription)
      }
      results.append(result)
    }
    return results
  }

  private func validate(root: URL, tmp: URL) throws {
    let info = try manager.attributesOfItem(atPath: tmp.path)
    guard root.pathComponents.count > 2, root.path != manager.homeDirectoryForCurrentUser.path,
      info[.type] as? FileAttributeType == .typeDirectory,
      tmp.resolvingSymlinksInPath().deletingLastPathComponent().path == root.path
    else { throw CleanupError.unsafePath }
  }

  private func facts(_ entry: URL, cutoff: Date, deadline: Date) throws -> Facts {
    var result = Facts()
    var pending = [entry]
    while let file = pending.popLast() {
      guard Date() < deadline, result.count < itemLimit else { throw CleanupError.scanLimit }
      // 一次 lstat 同时取得时间、类型和大小；不读内容、不跟随链接，也不重复请求访问时间。
      var info = stat()
      guard lstat(file.path, &info) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      let type = info.st_mode & S_IFMT
      result.count += 1
      if file == entry { result.inode = UInt64(info.st_ino) }
      let name = file.lastPathComponent
      if name == ".keep" || name == ".pimac-keep" || name.hasSuffix(".lock")
        || name.hasSuffix(".pid") || type == S_IFSOCK
      {
        result.preserved = true
        return result
      }
      // 根链接不属于本平台可判定的临时内容；内部链接只看链接本身，不访问目标。
      if file == entry && type == S_IFLNK {
        result.preserved = true
        return result
      }
      result.newest = max(
        result.newest, Self.date(info.st_mtimespec), Self.date(info.st_birthtimespec))
      if type == S_IFREG {
        result.newest = max(result.newest, Self.date(info.st_atimespec))
        result.bytes += Int64(info.st_size)
      }
      if result.newest >= cutoff { return result }
      if type == S_IFDIR {
        let children = try manager.contentsOfDirectory(at: file, includingPropertiesForKeys: nil)
        // 先检查直接保留标记，避免遍历大子树后才遇到 .keep。
        if children.contains(where: {
          let name = $0.lastPathComponent
          return name == ".keep" || name == ".pimac-keep" || name.hasSuffix(".lock")
            || name.hasSuffix(".pid")
        }) {
          result.preserved = true
          return result
        }
        pending += children
      } else if type != S_IFREG && type != S_IFLNK {
        result.preserved = true
        return result
      }
    }
    return result
  }

  private static func date(_ time: timespec) -> Date {
    Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
  }

  private func trackedPaths(root: URL) throws -> [URL] {
    let response = try command("/usr/bin/git", ["-C", root.path, "ls-files", "-z", "--", "tmp"])
    if response.status == 128 && response.output.contains("not a git repository") { return [] }
    guard response.status == 0 else { throw CleanupError.commandFailed("Git 跟踪文件") }
    return response.output.split(separator: "\0").map { root.appendingPathComponent(String($0)) }
  }

  private func liveReferences() throws -> String {
    let files = try command("/usr/sbin/lsof", ["-nP", "-u", String(getuid()), "-Fn"])
    let processes = try command("/bin/ps", ["-U", String(getuid()), "-o", "command="])
    guard files.status == 0, processes.status == 0 else {
      throw CleanupError.commandFailed("运行中进程和打开文件")
    }
    // 命令行可能含凭据，只用于内存中的路径保护，绝不写入清理记录或错误文案。
    return files.output + "\n" + processes.output
  }

  private static func contains(_ parent: URL, _ child: URL) -> Bool {
    child.path == parent.path || child.path.hasPrefix(parent.path + "/")
  }

  private func command(_ executable: String, _ arguments: [String]) throws -> (
    status: Int32, output: String
  ) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in
      new
    }
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timeout.schedule(deadline: .now() + 5)
    timeout.setEventHandler {
      if process.isRunning {
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
          if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
      }
    }
    timeout.resume()
    defer {
      // 失败与输出超限也必须等待自己启动的子进程退出，不能遗留后台检查进程。
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
      timeout.cancel()
      try? pipe.fileHandleForReading.close()
    }
    var data = Data()
    while let part = try pipe.fileHandleForReading.read(upToCount: 16_384), !part.isEmpty {
      if data.count + part.count > 8 * 1024 * 1024 {
        process.terminate()
        throw CleanupError.commandFailed("进程检查输出（超过上限）")
      }
      data.append(part)
    }
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}

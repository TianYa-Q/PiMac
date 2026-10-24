import Darwin
import Foundation

struct TaskLogSnapshot: Equatable, Sendable {
  let text: String
  let isTruncated: Bool
}

/// 每次重新打开以支持日志截断/轮转；只读末尾有界窗口，不长期持有文件或启动 tail 进程。
actor TaskLogReader {
  static let maximumBytes = 64 * 1024

  func read(_ source: TaskLogSource) throws -> TaskLogSnapshot {
    let root = source.root.resolvingSymlinksInPath().standardizedFileURL.path
    let expected = source.file.resolvingSymlinksInPath().standardizedFileURL.path
    guard root != "/", expected.hasPrefix(root + "/") else { throw Failure.outsideWorkspace }
    let fd = open(source.file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.unavailable(errno) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw Failure.unavailable(errno) }
    guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegular }
    // 打开后按真实 fd 再核验，防止父目录/符号链接在检查与 open 之间被换到工作区外。
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(fd, F_GETPATH, &buffer) == 0 else { throw Failure.unavailable(errno) }
    let opened = String(cString: buffer)
    guard opened == expected, opened.hasPrefix(root + "/") else { throw Failure.outsideWorkspace }
    let offset = max(0, info.st_size - off_t(Self.maximumBytes))
    var bytes = [UInt8](repeating: 0, count: Self.maximumBytes)
    let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, offset) }
    guard count >= 0 else { throw Failure.unavailable(errno) }
    var data = Data(bytes.prefix(count))
    // 尾部可能从 UTF-8 字符或半行中间开始；明确标注截断，不把半行伪装成完整日志。
    if offset > 0 {
      if let newline = data.firstIndex(of: 10) {
        data = Data(data.suffix(from: data.index(after: newline)))
      } else {
        data = Data(data.drop(while: { $0 & 0xC0 == 0x80 }))
      }
    }
    return TaskLogSnapshot(text: String(decoding: data, as: UTF8.self), isTruncated: offset > 0)
  }

  enum Failure: LocalizedError {
    case outsideWorkspace, notRegular
    case unavailable(Int32)
    var errorDescription: String? {
      switch self {
      case .outsideWorkspace: "日志路径已离开当前工作区，停止读取"
      case .notRegular: "日志不是普通文件，无法读取"
      case .unavailable(let code): "日志读取失败：\(String(cString: strerror(code)))"
      }
    }
  }
}

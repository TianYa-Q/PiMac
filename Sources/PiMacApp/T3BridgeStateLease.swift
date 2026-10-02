import Darwin
import Foundation

/// Held by the supervisor until the old sidecar actually exits, not merely until stop()
/// is requested. flock is released by the OS on an application crash.
final class T3BridgeStateLease: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptor: Int32

  init(directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    var directoryInfo = stat()
    guard lstat(directory.path, &directoryInfo) == 0,
      directoryInfo.st_mode & S_IFMT == S_IFDIR, directoryInfo.st_uid == getuid()
    else { throw LeaseError.unsafeDirectory }
    guard chmod(directory.path, 0o700) == 0 else { throw LeaseError.unsafeDirectory }
    let path = directory.appendingPathComponent("owner.lock").path
    let fd = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw LeaseError.unsafeLock }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), fchmod(fd, 0o600) == 0
    else {
      Darwin.close(fd)
      throw LeaseError.unsafeLock
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(fd)
      throw LeaseError.alreadyOwned
    }
    descriptor = fd
  }

  func release() {
    lock.lock()
    defer { lock.unlock() }
    guard descriptor >= 0 else { return }
    flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
    descriptor = -1
  }

  deinit { release() }

  enum LeaseError: Error {
    case unsafeDirectory
    case unsafeLock
    case alreadyOwned
  }
}

import Darwin
import Foundation

/// Upstream consumes this short-lived marker to preserve the managed tunnel during an update.
/// Ordinary quit must not write it: the relay should still release an offline environment.
enum T3UpdateRestart {
  static func prepare(in bridgeDirectory: URL) throws {
    let serverDirectory = bridgeDirectory.appendingPathComponent("server-owned", isDirectory: true)
    let runtimeDirectory = serverDirectory.appendingPathComponent("runtime", isDirectory: true)
    try requirePrivateDirectory(serverDirectory)
    if !FileManager.default.fileExists(atPath: runtimeDirectory.path) {
      try FileManager.default.createDirectory(
        at: runtimeDirectory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    try requirePrivateDirectory(runtimeDirectory)
    let marker = runtimeDirectory.appendingPathComponent("desktop-update-restart")
    // Do not follow a pre-existing marker symlink or truncate someone else's file.
    let fd = Darwin.open(marker.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw T3BridgeStateLease.LeaseError.unsafeLock }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_nlink == 1,
      fchmod(fd, 0o600) == 0, ftruncate(fd, 0) == 0,
      futimes(fd, nil) == 0, fsync(fd) == 0
    else { throw T3BridgeStateLease.LeaseError.unsafeLock }
  }

  private static func requirePrivateDirectory(_ directory: URL) throws {
    var info = stat()
    guard lstat(directory.path, &info) == 0,
      info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
      info.st_mode & 0o077 == 0
    else { throw T3BridgeStateLease.LeaseError.unsafeDirectory }
  }
}

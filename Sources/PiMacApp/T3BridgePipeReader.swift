import Darwin
import Foundation

/// A child-lifetime reader, independent of AppKit run-loop/file-handle notifications.
/// Each launch has its own queue and decoder; an exiting child's partial record can
/// never contaminate its replacement. Termination/closed child stdout wakes read().
enum T3BridgePipeReader {
  static func start(
    _ handle: FileHandle, onRecord: (@Sendable (Data) -> Void)? = nil
  ) {
    DispatchQueue(label: "pimac.t3.pipe.\(UUID().uuidString)", qos: .userInitiated).async {
      defer { try? handle.close() }
      let decoder = JSONLineDecoder()
      var bytes = [UInt8](repeating: 0, count: 16 * 1024)
      while true {
        // POSIX read returns the currently available bytes, not a full buffer.
        // The handle stays owned by this queue until EOF: never close a descriptor
        // concurrently with read(), where it could be reused by a new process.
        let count = bytes.withUnsafeMutableBytes {
          Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
        }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return }
        guard let onRecord else { continue }
        for record in decoder.append(Data(bytes.prefix(count))) { onRecord(record) }
      }
    }
  }
}

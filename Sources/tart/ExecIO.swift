import Foundation

// Avoid Tart's Darwin type shadowing the system module.
private let closeExecDescriptor = close

/// Own all of an exec session's descriptors together. dup() aliases share status
/// flags: let every DispatchIO channel save nonblocking flags, then restore the
/// original flags only after *all* channels relinquish their descriptors.
final class ExecIO: @unchecked Sendable {
  let channels: [DispatchIO]
  private let closed = DispatchGroup()

  init(fileDescriptors: [Int32]) throws {
    var descriptors: [(fd: Int32, flags: Int32)] = []
    do {
      // Snapshot everything before changing any flags, including aliases such
      // as an interactive terminal or stdout/stderr redirected with 2>&1.
      for original in fileDescriptors {
        let flags = fcntl(original, F_GETFL)
        guard flags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        let fd = fcntl(original, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        descriptors.append((fd, flags))
      }
      for descriptor in descriptors {
        guard fcntl(descriptor.fd, F_SETFL, descriptor.flags | O_NONBLOCK) == 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }
      }
    } catch {
      for descriptor in descriptors {
        _ = fcntl(descriptor.fd, F_SETFL, descriptor.flags)
        _ = closeExecDescriptor(descriptor.fd)
      }
      throw error
    }

    let ownedDescriptors = descriptors
    let cleanup = DispatchGroup()
    let queue = DispatchQueue(label: "org.cirruslabs.tart.exec.io-cleanup")
    channels = ownedDescriptors.map { descriptor in
      cleanup.enter()
      return DispatchIO(type: .stream, fileDescriptor: descriptor.fd, queue: queue) { _ in
        cleanup.leave()
      }
    }
    let closed = self.closed
    closed.enter()
    cleanup.notify(queue: queue) {
      for descriptor in ownedDescriptors {
        _ = fcntl(descriptor.fd, F_SETFL, descriptor.flags)
        _ = closeExecDescriptor(descriptor.fd)
      }
      closed.leave()
    }
  }

  deinit { cancel() }

  func cancel() {
    for channel in channels { channel.close(flags: .stop) }
  }

  func close() async {
    cancel()
    await withCheckedContinuation { continuation in
      closed.notify(queue: .global()) { continuation.resume() }
    }
  }
}

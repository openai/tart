import Darwin
import Foundation
import Semaphore
import System
import Virtualization

class NetworkFD: Network {
  private let attachment: VZFileHandleNetworkDeviceAttachment

  init(fd: Int32) throws {
    do {
      try Softnet.validateControlFD(fd, type: SOCK_DGRAM)
    } catch {
      throw RuntimeError.Generic("--net-fd \(error)")
    }

    let flags = fcntl(fd, F_GETFD)
    guard flags != -1 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) != -1 else {
      throw RuntimeError.Generic("failed to set close-on-exec on --net-fd: \(Errno(rawValue: errno))")
    }

    let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: fileHandle)
  }

  func attachments() -> [VZNetworkDeviceAttachment] {
    [attachment]
  }

  func run(_ sema: AsyncSemaphore) throws {
    // no-op, only used for Softnet
  }

  func stop() async throws {
    // no-op, only used for Softnet
  }
}

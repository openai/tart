import CTartExecIO
import Foundation

/// Blocking transfers run on private, cancellable native workers. Unlike
/// DispatchIO, this never changes O_NONBLOCK on an inherited file description,
/// even when unrelated exec processes share the same pipe or terminal.
final class ExecChannel: @unchecked Sendable {
  private struct Worker: @unchecked Sendable {
    let pointer: OpaquePointer
  }

  private let queue = DispatchQueue(label: "org.cirruslabs.tart.exec.io")
  private let lock = NSLock()
  private let closed = DispatchGroup()
  private var worker: Worker?

  init(fileDescriptor: Int32) throws {
    var error: Int32 = 0
    guard let pointer = tart_exec_io_create(fileDescriptor, &error) else {
      throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
    }
    worker = Worker(pointer: pointer)
    closed.enter()
  }

  deinit { cancel() }

  private func submit(_ operation: @escaping @Sendable (Worker) -> Void) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let worker else { return false }
    queue.async { operation(worker) }
    return true
  }

  func read(length: Int, queue callbackQueue: DispatchQueue, completion: @escaping @Sendable (Data, Int32) -> Void) {
    if !submit({ worker in
      var data = Data(count: length)
      var transferred = 0
      let error = data.withUnsafeMutableBytes {
        tart_exec_io_read(worker.pointer, $0.baseAddress, $0.count, &transferred)
      }
      data.count = error == 0 ? transferred : 0
      let result = data
      callbackQueue.async { completion(result, error) }
    }) {
      callbackQueue.async { completion(Data(), ECANCELED) }
    }
  }

  func write(_ data: Data, queue callbackQueue: DispatchQueue, completion: @escaping @Sendable (Int32) -> Void) {
    if !submit({ worker in
      let error = data.withUnsafeBytes {
        tart_exec_io_write(worker.pointer, $0.baseAddress, $0.count)
      }
      callbackQueue.async { completion(error) }
    }) {
      callbackQueue.async { completion(ECANCELED) }
    }
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    guard let worker else { return }
    self.worker = nil
    tart_exec_io_cancel(worker.pointer)
    // Destruction runs after any accepted transfer returns.
    let closed = self.closed
    queue.async {
      tart_exec_io_destroy(worker.pointer)
      closed.leave()
    }
  }

  func close() async {
    cancel()
    await withCheckedContinuation { continuation in
      closed.notify(queue: .global()) { continuation.resume() }
    }
  }
}

final class ExecIO: @unchecked Sendable {
  let channels: [ExecChannel]

  init(fileDescriptors: [Int32]) throws {
    // Validate all originals before any duplicate can occupy a closed one.
    for fd in fileDescriptors {
      guard fcntl(fd, F_GETFL) >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    channels = try fileDescriptors.map { try ExecChannel(fileDescriptor: $0) }
  }

  deinit { cancel() }

  func cancel() {
    for channel in channels { channel.cancel() }
  }

  func close() async {
    cancel()
    for channel in channels { await channel.close() }
  }
}

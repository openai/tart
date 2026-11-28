import Foundation

/// A demand-driven stdin reader. Each native read is bounded and can return
/// partial input immediately, without changing the caller's descriptor flags.
final class ExecInput: @unchecked Sendable {
  static let chunkSize = 64 * 1024

  private let queue = DispatchQueue(label: "org.cirruslabs.tart.exec.stdin")
  private let io: ExecChannel
  private let owner: ExecIO?
  // Accessed only on queue.
  private var reading = false
  private var ended = false

  convenience init(fileDescriptor: Int32) throws {
    let owner = try ExecIO(fileDescriptors: [fileDescriptor])
    self.init(io: owner.channels[0], owner: owner)
  }

  init(io: ExecChannel, owner: ExecIO? = nil) {
    self.io = io
    self.owner = owner
  }

  deinit { cancel() }

  func next() async throws -> Data? {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let data: Data? = try await withCheckedThrowingContinuation { continuation in
        queue.async {
          precondition(!self.reading)
          if self.ended {
            continuation.resume(returning: nil)
            return
          }
          self.reading = true
          self.io.read(length: Self.chunkSize, queue: self.queue) { data, error in
            self.reading = false
            if error == ECANCELED {
              continuation.resume(throwing: CancellationError())
            } else if error != 0 {
              continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
            } else {
              self.ended = data.isEmpty
              continuation.resume(returning: self.ended ? nil : data)
            }
          }
        }
      }
      try Task.checkCancellation()
      return data
    } onCancel: {
      self.cancel()
    }
  }

  func cancel() { io.cancel() }
}

/// Do not pull the next chunk until the preceding transport write has completed.
/// EOF is a protocol message, not the end of the RPC (PTY resizing may continue).
func sendExecInput(_ input: ExecInput, send: (Data) async throws -> Void) async throws {
  while let data = try await input.next() {
    try Task.checkCancellation()
    try await send(data)
  }
  try Task.checkCancellation()
  try await send(Data())
}

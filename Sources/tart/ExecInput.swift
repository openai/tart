import Foundation

/// A demand-driven stdin reader. DispatchIO keeps blocking file I/O off Swift's
/// cooperative executor and can cancel an idle pipe/terminal read. A read operation
/// may deliver partial chunks (important for terminals), but reads at most 64 KiB.
final class ExecInput: @unchecked Sendable {
  static let chunkSize = 64 * 1024

  private let queue = DispatchQueue(label: "org.cirruslabs.tart.exec.stdin")
  private let io: DispatchIO
  private let owner: ExecIO?
  // Accessed only on queue.
  private var chunks: [Data] = []
  private var reading = false
  private var ended = false
  private var failure: Error?
  private var waiter: CheckedContinuation<Data?, Error>?

  convenience init(fileDescriptor: Int32) throws {
    let owner = try ExecIO(fileDescriptors: [fileDescriptor])
    self.init(io: owner.channels[0], owner: owner)
  }

  init(io: DispatchIO, owner: ExecIO? = nil) {
    self.io = io
    self.owner = owner
    io.setLimit(lowWater: 1)
    io.setLimit(highWater: Self.chunkSize)
  }

  deinit {
    io.close(flags: .stop)
  }

  func next() async throws -> Data? {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          precondition(self.waiter == nil)
          self.waiter = continuation
          self.deliver()
          self.readIfNeeded()
        }
      }
    } onCancel: {
      self.cancel()
    }
  }

  func cancel() {
    queue.async {
      self.failure = CancellationError()
      self.chunks.removeAll()
      self.io.close(flags: .stop)
      self.deliver()
    }
  }

  private func readIfNeeded() {
    guard waiter != nil && !reading && !ended && failure == nil else { return }
    reading = true
    var bytesRead = 0
    io.read(offset: 0, length: Self.chunkSize, queue: queue) { done, data, error in
      if self.failure != nil { return }
      if let data, !data.isEmpty {
        bytesRead += data.count
        self.chunks.append(Data(data))
      }
      if error != 0 {
        self.failure = POSIXError(POSIXErrorCode(rawValue: error)!)
      }
      if done {
        self.reading = false
        self.ended = bytesRead < Self.chunkSize
      }
      self.deliver()
      self.readIfNeeded()
    }
  }

  private func deliver() {
    guard let waiter else { return }
    if let failure {
      self.waiter = nil
      waiter.resume(throwing: failure)
    } else if !chunks.isEmpty {
      self.waiter = nil
      waiter.resume(returning: chunks.removeFirst())
    } else if ended {
      self.waiter = nil
      waiter.resume(returning: nil)
    }
  }
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

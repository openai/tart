import Foundation
import GRPC
import NIOCore
import Cirruslabs_TartGuestAgent_Apple_Swift

/// Serialize output without blocking the gRPC event loop. Manual HTTP/2 stream
/// reads limit the response queue to a read cycle; the peer's flow-control window
/// bounds frames held by NIO while the host's stdout/stderr is stalled.
final class ExecOutput: @unchecked Sendable {
  let eventLoop: EventLoop
  let completion: EventLoopPromise<Void>
  private let stdout: DispatchIO
  private let stderr: DispatchIO
  private let queue: DispatchQueue
  // Accessed only on eventLoop.
  private var channel: Channel?
  private var responses: [ExecResponse] = []
  private var writing = false
  private var canRead = false
  private var terminal: Result<Void, Error>?
  private var finished = false

  init(eventLoop: EventLoop, stdout: DispatchIO, stderr: DispatchIO) {
    queue = DispatchQueue(label: "org.cirruslabs.tart.exec.output")
    self.eventLoop = eventLoop
    self.stdout = stdout
    self.stderr = stderr
    completion = eventLoop.makePromise()
  }

  func configure(_ channel: Channel) async throws {
    try await channel.setOption(ChannelOptions.autoRead, value: false).get()
    try await channel.pipeline.addHandler(ExecReadCompleteHandler { [self] in
      eventLoop.execute {
        self.canRead = true
        self.drain()
      }
    }).get()
    try await eventLoop.submit {
      self.channel = channel
      self.canRead = false
      channel.read()
    }.get()
  }

  func receive(_ response: ExecResponse) {
    eventLoop.execute {
      guard !self.finished else { return }
      self.responses.append(response)
      self.drain()
    }
  }

  func end(_ result: Result<Void, Error>) {
    eventLoop.execute {
      guard !self.finished else { return }
      if self.terminal == nil { self.terminal = result }
      self.drain()
    }
  }

  func cancel() {
    eventLoop.execute { self.finish(.failure(CancellationError())) }
  }

  private func drain() {
    guard !finished && !writing else { return }
    while !responses.isEmpty {
      let response = responses.removeFirst()
      let io: DispatchIO
      let data: Data
      switch response.type {
      case .standardOutput(let chunk):
        io = stdout
        data = chunk.data
      case .standardError(let chunk):
        io = stderr
        data = chunk.data
      case .exit(let exit):
        finish(.failure(ExecCustomExitCodeError(exitCode: exit.code)))
        return
      default:
        continue
      }
      writing = true
      let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
      io.write(offset: 0, data: bytes, queue: queue) { done, _, error in
        if done || error != 0 {
          self.eventLoop.execute {
            self.writing = false
            if error != 0 {
              self.finish(.failure(POSIXError(POSIXErrorCode(rawValue: error)!)))
            } else {
              self.drain()
            }
          }
        }
      }
      return
    }
    if let terminal {
      finish(terminal)
    } else if canRead, let channel {
      canRead = false
      channel.read()
    }
  }

  private func finish(_ result: Result<Void, Error>) {
    guard !finished else { return }
    finished = true
    responses.removeAll()
    channel = nil
    stdout.close(flags: .stop)
    stderr.close(flags: .stop)
    completion.completeWith(result)
  }
}

private final class ExecReadCompleteHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = Never
  let onReadComplete: () -> Void

  init(_ onReadComplete: @escaping () -> Void) {
    self.onReadComplete = onReadComplete
  }

  func channelReadComplete(context: ChannelHandlerContext) {
    context.fireChannelReadComplete()
    onReadComplete()
  }
}

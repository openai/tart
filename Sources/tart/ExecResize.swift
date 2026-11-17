import Foundation
import NIOCore

/// Suspend signal delivery while a resize is being written. Dispatch coalesces
/// SIGWINCH while suspended; we query the current size on the next delivery.
final class ExecResize: @unchecked Sendable {
  private let queue = DispatchQueue(label: "org.cirruslabs.tart.exec.resize")
  private let source: DispatchSourceSignal
  private var suspended = false
  private var cancelled = false

  init(
    size: @escaping () throws -> (width: UInt16, height: UInt16),
    send: @escaping (Int, Int) -> EventLoopFuture<Void>,
    onError: @escaping (Error) -> Void
  ) {
    signal(SIGWINCH, SIG_IGN)
    source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: queue)
    source.setEventHandler { [self] in
      source.suspend()
      suspended = true
      do {
        let (width, height) = try size()
        send(Int(width), Int(height)).whenComplete { result in
          self.queue.async {
            if case .failure(let error) = result { onError(error) }
            if self.suspended {
              self.suspended = false
              self.source.resume()
            }
          }
        }
      } catch {
        onError(error)
        suspended = false
        source.resume()
      }
    }
    source.activate()
  }

  func cancel() {
    queue.async {
      guard !self.cancelled else { return }
      self.cancelled = true
      self.source.cancel()
      self.source.setEventHandler {}
      if self.suspended {
        self.suspended = false
        self.source.resume()
      }
    }
  }
}

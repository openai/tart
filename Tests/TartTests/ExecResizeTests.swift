import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import tart

final class ExecResizeTests: XCTestCase {
  func testResizeDeliveryWaitsForSendAndCancellationReleasesSuspendedSource() async throws {
    let previous = signal(SIGWINCH, SIG_IGN)
    defer { signal(SIGWINCH, previous) }
    let loop = MultiThreadedEventLoopGroup.singleton.next()
    let sent = expectation(description: "first resize sent")
    let write = loop.makePromise(of: Void.self)
    let sends = ExecTestBytes()
    var resize: ExecResize? = ExecResize(size: { (80, 24) }) { width, height in
      XCTAssertEqual(width, 80)
      XCTAssertEqual(height, 24)
      if sends.append(Data([1])) == 1 { sent.fulfill() }
      return write.futureResult
    } onError: { _ in }
    weak var released = resize
    XCTAssertEqual(kill(getpid(), SIGWINCH), 0)
    await fulfillment(of: [sent], timeout: 5)
    for _ in 0..<16 { XCTAssertEqual(kill(getpid(), SIGWINCH), 0) }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(sends.data.count, 1)
    resize?.cancel()
    resize = nil
    // Real RPC cancellation fails the in-flight send promise as well.
    write.fail(CancellationError())
    // Dispatch source cancellation is asynchronous. Observe eventual release,
    // bounded by a deadline, rather than assuming it finishes in this thread.
    for _ in 0..<100 where released != nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNil(released)
  }
}

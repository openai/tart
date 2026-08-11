import XCTest
@testable import tart

final class DropCancellationTokenTests: XCTestCase {
  func testFlagFlips() {
    let t = DropCancellationToken()
    XCTAssertFalse(t.isCancelled)
    t.cancel()
    XCTAssertTrue(t.isCancelled)
  }

  func testOnCancelRunsWhenCancelled() {
    let t = DropCancellationToken()
    var fired = 0
    t.onCancel { fired += 1 }
    XCTAssertEqual(fired, 0, "must not fire before cancel")
    t.cancel()
    XCTAssertEqual(fired, 1)
  }

  func testOnCancelRunsImmediatelyIfAlreadyCancelled() {
    let t = DropCancellationToken()
    t.cancel()
    var fired = 0
    t.onCancel { fired += 1 }
    XCTAssertEqual(fired, 1, "late handler must run at once on an already-cancelled token")
  }

  func testCancelIsIdempotentAndHandlersRunOnce() {
    let t = DropCancellationToken()
    var fired = 0
    t.onCancel { fired += 1 }
    t.cancel()
    t.cancel()
    XCTAssertEqual(fired, 1, "handlers must run exactly once across repeated cancels")
  }

  func testMultipleHandlersAllRun() {
    let t = DropCancellationToken()
    var a = false
    var b = false
    t.onCancel { a = true }
    t.onCancel { b = true }
    t.cancel()
    XCTAssertTrue(a && b)
  }
}

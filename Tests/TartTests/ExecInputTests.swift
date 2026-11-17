import Foundation
import XCTest
@testable import tart

final class ExecInputTests: XCTestCase {
  func testFileIsPulledOnlyAfterSendCompletesAndEOFIsSentOnce() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bytes = Data((0..<(ExecInput.chunkSize * 3 + 17)).map { UInt8(truncatingIfNeeded: $0) })
    try bytes.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let input = try ExecInput(fileDescriptor: handle.fileDescriptor)
    defer { input.cancel() }
    XCTAssertEqual(try handle.offset(), 0)

    let firstSend = expectation(description: "first send")
    let finished = expectation(description: "input finished")
    let gate = ExecTestGate()
    let received = ExecTestBytes()
    let task = Task {
      do {
        try await sendExecInput(input) { data in
          if received.append(data) == 1 {
            firstSend.fulfill()
            await gate.wait()
          }
        }
      } catch { XCTFail("\(error)") }
      finished.fulfill()
    }
    defer { task.cancel() }
    await fulfillment(of: [firstSend], timeout: 5)
    XCTAssertEqual(try handle.offset(), UInt64(ExecInput.chunkSize))
    await gate.open()
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertEqual(received.data, bytes)
    XCTAssertEqual(received.emptyCount, 1)
    XCTAssertLessThanOrEqual(received.largest, ExecInput.chunkSize)
  }

  func testPipeDeliversPartialInputBeforeEOFAndWaitsForSend() async throws {
    let pipe = Pipe()
    let input = try ExecInput(fileDescriptor: pipe.fileHandleForReading.fileDescriptor)
    defer { input.cancel() }
    let sent = expectation(description: "partial input sent while pipe remains open")
    let finished = expectation(description: "EOF delivered")
    let gate = ExecTestGate()
    let received = ExecTestBytes()
    let task = Task {
      do {
        try await sendExecInput(input) { data in
          if received.append(data) == 1 {
            sent.fulfill()
            await gate.wait()
          }
        }
      } catch { XCTFail("\(error)") }
      finished.fulfill()
    }
    defer { task.cancel() }
    let first = Data("interactive input\n".utf8)
    try pipe.fileHandleForWriting.write(contentsOf: first)
    await fulfillment(of: [sent], timeout: 5)
    let second = Data("second input\n".utf8)
    try pipe.fileHandleForWriting.write(contentsOf: second)
    XCTAssertEqual(received.data, first)
    try pipe.fileHandleForWriting.close()
    await gate.open()
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertEqual(received.data, first + second)
    XCTAssertEqual(received.emptyCount, 1)
  }

  func testEmptyAndExactChunkSizedFilesHaveOneEOF() async throws {
    for count in [0, ExecInput.chunkSize, ExecInput.chunkSize + 1] {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let bytes = Data(repeating: 19, count: count)
      try bytes.write(to: url)
      defer { try? FileManager.default.removeItem(at: url) }
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let input = try ExecInput(fileDescriptor: handle.fileDescriptor)
      defer { input.cancel() }
      let received = ExecTestBytes()
      try await sendExecInput(input) { _ = received.append($0) }
      XCTAssertEqual(received.data, bytes)
      XCTAssertEqual(received.emptyCount, 1)
    }
  }

  func testCancellingIdlePipeReadDoesNotRequireClosingWriter() async throws {
    let pipe = Pipe()
    let input = try ExecInput(fileDescriptor: pipe.fileHandleForReading.fileDescriptor)
    let done = expectation(description: "cancelled idle read")
    let task = Task {
      do {
        _ = try await input.next()
        XCTFail("Expected cancellation")
      } catch { XCTAssertTrue(error is CancellationError) }
      done.fulfill()
    }
    task.cancel()
    await fulfillment(of: [done], timeout: 5)
    // The caller's descriptor remains open and usable after reader cleanup.
    try pipe.fileHandleForWriting.write(contentsOf: Data([42]))
  }

  func testReadFailureAndInvalidDescriptor() async throws {
    XCTAssertThrowsError(try ExecInput(fileDescriptor: -1))
    let pipe = Pipe()
    let input = try ExecInput(fileDescriptor: pipe.fileHandleForWriting.fileDescriptor)
    defer { input.cancel() }
    do {
      _ = try await input.next()
      XCTFail("Reading a write-only descriptor must fail")
    } catch { XCTAssertTrue(error is POSIXError) }
  }

  func testSendErrorStopsPullingWithoutSendingEOF() async throws {
    let pipe = Pipe()
    try pipe.fileHandleForWriting.write(contentsOf: Data([1, 2, 3]))
    let input = try ExecInput(fileDescriptor: pipe.fileHandleForReading.fileDescriptor)
    defer { input.cancel() }
    var sends = 0
    do {
      try await sendExecInput(input) { _ in
        sends += 1
        throw ExecTestError.send
      }
      XCTFail("Expected send failure")
    } catch { XCTAssertTrue(error is ExecTestError) }
    XCTAssertEqual(sends, 1)
  }
}

private enum ExecTestError: Error { case send }

actor ExecTestGate {
  private var opened = false
  private var waiter: CheckedContinuation<Void, Never>?

  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func open() {
    opened = true
    waiter?.resume()
    waiter = nil
  }
}

final class ExecTestBytes: @unchecked Sendable {
  private let lock = NSLock()
  private var chunks: [Data] = []

  func append(_ data: Data) -> Int {
    lock.lock()
    defer { lock.unlock() }
    chunks.append(data)
    return chunks.count
  }

  var data: Data { snapshot.reduce(into: Data()) { $0.append($1) } }
  var emptyCount: Int { snapshot.filter(\.isEmpty).count }
  var largest: Int { snapshot.map(\.count).max() ?? 0 }
  private var snapshot: [Data] {
    lock.lock()
    defer { lock.unlock() }
    return chunks
  }
}

import Foundation
import XCTest
@testable import tart

final class ExecIOTests: XCTestCase {
  func testInitializationFailuresRestoreEarlierDescriptors() throws {
    let pipe = Pipe()
    let fd = pipe.fileHandleForWriting.fileDescriptor
    let flags = execTestFileStatus(fd)
    XCTAssertThrowsError(try ExecIO(fileDescriptors: [-1, fd]))
    XCTAssertThrowsError(try ExecIO(fileDescriptors: [fd, -1]))
    XCTAssertEqual(execTestFileStatus(fd), flags)
  }

  func testClosedOriginalIsNotMistakenForADuplicate() throws {
    let pipe = Pipe()
    let fd = pipe.fileHandleForWriting.fileDescriptor
    let flags = execTestFileStatus(fd)
    // The next lowest available descriptor is exactly where the old code
    // would duplicate the first original, making the closed input look valid.
    let missing = fcntl(fd, F_DUPFD_CLOEXEC, 0)
    XCTAssertGreaterThanOrEqual(missing, 0)
    guard missing >= 0 else { return }
    _ = close(missing)
    XCTAssertThrowsError(try ExecIO(fileDescriptors: [fd, missing]))
    XCTAssertEqual(execTestFileStatus(fd), flags)
  }

  func testAliasedPipeFlagsAreRestoredAfterAllChannelsClose() async throws {
    let pipe = Pipe()
    let fd = pipe.fileHandleForWriting.fileDescriptor
    let flags = execTestFileStatus(fd)
    let io = try ExecIO(fileDescriptors: [fd, fd])
    try await write(Data([1]), to: io.channels[0])
    // Closing one channel must leave the caller and its other alias untouched.
    io.channels[0].cancel()
    try await write(Data([2]), to: io.channels[1])
    XCTAssertEqual(execTestFileStatus(fd), flags)
    await io.close()
    XCTAssertEqual(execTestFileStatus(fd), flags)
    XCTAssertEqual(try pipe.fileHandleForReading.read(upToCount: 2), Data([1, 2]))
  }

  func testAliasedPTYFlagsAndIdleReadAreRestoredOnCancellation() async throws {
    let (master, slave) = try makeExecTestPTY()
    let fd = slave.fileDescriptor
    let flags = execTestFileStatus(fd)
    let io = try ExecIO(fileDescriptors: [fd, fd, fd])
    let input = ExecInput(io: io.channels[0])
    let read = Task { try await input.next() }
    try master.write(contentsOf: Data([7]))
    let data = try await read.value
    XCTAssertEqual(data, Data([7]), "Raw PTY input must not wait for a newline or EOF")
    let idle = Task { try await input.next() }
    idle.cancel()
    do { _ = try await idle.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    // This write uses an alias after the input channel was stopped.
    try await write(Data([8]), to: io.channels[1])
    await io.close()
    XCTAssertEqual(execTestFileStatus(fd), flags)
    XCTAssertEqual(try master.read(upToCount: 1), Data([8]))
  }

  func testOverlappingOwnersKeepInheritedFlagsAndRemainUsable() async throws {
    for reversed in [false, true] {
      let pipe = Pipe()
      let fd = pipe.fileHandleForWriting.fileDescriptor
      let flags = execTestFileStatus(fd)
      let first = try ExecIO(fileDescriptors: [fd])
      let second = try ExecIO(fileDescriptors: [fd])
      XCTAssertEqual(execTestFileStatus(fd), flags)
      try await write(Data([1]), to: first.channels[0])
      try await write(Data([2]), to: second.channels[0])
      XCTAssertEqual(execTestFileStatus(fd), flags)
      let (closing, remaining) = reversed ? (second, first) : (first, second)
      await closing.close()
      XCTAssertEqual(execTestFileStatus(fd), flags)
      try await write(Data([3]), to: remaining.channels[0])
      await remaining.close()
      XCTAssertEqual(execTestFileStatus(fd), flags)
      XCTAssertEqual(try pipe.fileHandleForReading.read(upToCount: 3), Data([1, 2, 3]))
    }
  }

  func testAlreadyNonblockingInputAndCancellationPreserveFlags() async throws {
    let pipe = Pipe()
    let fd = pipe.fileHandleForReading.fileDescriptor
    let original = fcntl(fd, F_GETFL)
    XCTAssertEqual(fcntl(fd, F_SETFL, original | O_NONBLOCK), 0)
    defer { _ = fcntl(fd, F_SETFL, original) }
    let flags = execTestFileStatus(fd)
    let io = try ExecIO(fileDescriptors: [fd])
    let input = ExecInput(io: io.channels[0])
    let read = Task { try await input.next() }
    try pipe.fileHandleForWriting.write(contentsOf: Data([17]))
    let data = try await read.value
    XCTAssertEqual(data, Data([17]))
    let idle = Task { try await input.next() }
    idle.cancel()
    do { _ = try await idle.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    await io.close()
    XCTAssertEqual(execTestFileStatus(fd), flags)
  }

  func testClosedOutputPeerReturnsBrokenPipe() async throws {
    // Tests invoke ExecIO directly, without Root's exec signal setup.
    let previous = signal(SIGPIPE, SIG_IGN)
    defer { signal(SIGPIPE, previous) }
    let pipe = Pipe()
    try pipe.fileHandleForReading.close()
    let fd = pipe.fileHandleForWriting.fileDescriptor
    let flags = execTestFileStatus(fd)
    let io = try ExecIO(fileDescriptors: [fd])
    do {
      try await write(Data([1]), to: io.channels[0])
      XCTFail("Expected broken pipe")
    } catch let error as POSIXError {
      XCTAssertEqual(error.code, .EPIPE)
    }
    await io.close()
    XCTAssertEqual(execTestFileStatus(fd), flags)
  }

  private func write(_ data: Data, to channel: ExecChannel) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      channel.write(data, queue: .global()) { error in
        if error == 0 { continuation.resume() }
        else { continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: error)!)) }
      }
    }
  }
}

func makeExecTestPTY() throws -> (FileHandle, FileHandle) {
  var master: Int32 = -1
  var slave: Int32 = -1
  guard openpty(&master, &slave, nil, nil, nil) == 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno)!)
  }
  let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
  let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
  var attributes = termios()
  guard tcgetattr(slave, &attributes) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
  cfmakeraw(&attributes)
  guard tcsetattr(slave, TCSANOW, &attributes) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
  return (masterHandle, slaveHandle)
}

// Darwin also reports kernel bookkeeping such as FWASWRITTEN through F_GETFL.
// Compare the user-visible access/status flags, not whether a write occurred.
func execTestFileStatus(_ fd: Int32) -> Int32 {
  let flags = fcntl(fd, F_GETFL)
  XCTAssertGreaterThanOrEqual(flags, 0)
  return flags & (O_ACCMODE | O_NONBLOCK | O_APPEND | O_ASYNC | O_SYNC)
}

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

  func testAliasedPipeFlagsAreRestoredAfterAllChannelsClose() async throws {
    let pipe = Pipe()
    let fd = pipe.fileHandleForWriting.fileDescriptor
    let flags = execTestFileStatus(fd)
    let io = try ExecIO(fileDescriptors: [fd, fd])
    try await write(Data([1]), to: io.channels[0])
    // One channel relinquishing its descriptor must not make its alias block.
    io.channels[0].close(flags: .stop)
    try await write(Data([2]), to: io.channels[1])
    XCTAssertNotEqual(fcntl(fd, F_GETFL) & O_NONBLOCK, 0)
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

  private func write(_ data: Data, to channel: DispatchIO) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      channel.write(offset: 0, data: data.withUnsafeBytes { DispatchData(bytes: $0) }, queue: .global()) { done, _, error in
        if done {
          if error == 0 { continuation.resume() }
          else { continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: error)!)) }
        }
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

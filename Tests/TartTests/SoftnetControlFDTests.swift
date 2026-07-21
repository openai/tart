import XCTest
@testable import tart

import Semaphore

final class SoftnetControlFDTests: XCTestCase {
  func testConnectedUnixStreamSocketIsAccepted() throws {
    var fds: [Int32] = [-1, -1]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    defer {
      close(fds[0])
      close(fds[1])
    }

    XCTAssertNoThrow(try Softnet.validateControlFD(fds[0]))
  }

  func testUnixDatagramSocketIsRejected() throws {
    var fds: [Int32] = [-1, -1]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds), 0)
    defer {
      close(fds[0])
      close(fds[1])
    }

    XCTAssertThrowsError(try Softnet.validateControlFD(fds[0]))
  }

  func testUnconnectedUnixStreamSocketIsRejected() throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThan(fd, STDERR_FILENO)
    defer { close(fd) }

    XCTAssertThrowsError(try Softnet.validateControlFD(fd))
  }

  func testPipeIsRejected() throws {
    var fds: [Int32] = [-1, -1]
    XCTAssertEqual(pipe(&fds), 0)
    defer {
      close(fds[0])
      close(fds[1])
    }

    XCTAssertThrowsError(try Softnet.validateControlFD(fds[0]))
  }

  func testStandardDescriptorsAreRejected() throws {
    XCTAssertThrowsError(try Softnet.validateControlFD(STDIN_FILENO))
    XCTAssertThrowsError(try Softnet.validateControlFD(STDOUT_FILENO))
    XCTAssertThrowsError(try Softnet.validateControlFD(STDERR_FILENO))
  }

  func testControlChannelIsPassedToSoftnetAndVMFDRemainsDatagram() async throws {
    let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("softnet")
    let script = """
    #!/usr/bin/env python3
    import socket
    import sys

    assert sys.argv[1:] == ["--vm-fd", "0", "--vm-mac-address", "02:00:00:00:00:01", "--control-fd", "1"]
    vm = socket.socket(fileno=0)
    control = socket.socket(fileno=1)
    assert vm.family == socket.AF_UNIX and vm.type == socket.SOCK_DGRAM
    assert control.family == socket.AF_UNIX and control.type == socket.SOCK_STREAM
    assert control.recv(4096) == b"softnet.policy.set\\n"
    control.sendall(b"ok\\n")
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let previousPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    setenv("PATH", "\(temporaryDirectory.path):\(previousPath)", 1)
    defer { setenv("PATH", previousPath, 1) }

    var fds: [Int32] = [-1, -1]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    defer { close(fds[1]) }

    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    XCTAssertEqual(setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)), 0)

    let semaphore = AsyncSemaphore(value: 0)
    let softnet = try Softnet(vmMACAddress: "02:00:00:00:00:01", controlFD: fds[0])
    try softnet.run(semaphore)

    XCTAssertEqual(fcntl(fds[0], F_GETFD), -1)
    XCTAssertEqual(errno, EBADF)

    let request = Array("softnet.policy.set\n".utf8)
    XCTAssertEqual(request.withUnsafeBytes { send(fds[1], $0.baseAddress, $0.count, 0) }, request.count)

    var response = [UInt8](repeating: 0, count: 128)
    let received = recv(fds[1], &response, response.count, 0)
    XCTAssertGreaterThan(received, 0)
    XCTAssertEqual(String(decoding: response.prefix(Int(max(received, 0))), as: UTF8.self), "ok\n")

    await semaphore.wait()
  }

  func testControlFDIsClosedWhenSoftnetInitializationFails() throws {
    let previousPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    setenv("PATH", "/this/path/does/not/exist", 1)
    defer { setenv("PATH", previousPath, 1) }

    var fds: [Int32] = [-1, -1]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    defer { close(fds[1]) }

    XCTAssertThrowsError(try Softnet(vmMACAddress: "02:00:00:00:00:01", controlFD: fds[0]))
    XCTAssertEqual(fcntl(fds[0], F_GETFD), -1)
    XCTAssertEqual(errno, EBADF)
  }

  func testControlFDIsClosedWhenSoftnetValidationFails() throws {
    var fds: [Int32] = [-1, -1]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds), 0)
    defer { close(fds[1]) }

    XCTAssertThrowsError(try Softnet(vmMACAddress: "02:00:00:00:00:01", controlFD: fds[0]))
    XCTAssertEqual(fcntl(fds[0], F_GETFD), -1)
    XCTAssertEqual(errno, EBADF)
  }

  func testControlFDImpliesSoftnet() throws {
    let temporaryHome = try createTemporaryTartHome()
    defer { try? FileManager.default.removeItem(at: temporaryHome) }
    let previousHome = ProcessInfo.processInfo.environment["TART_HOME"]
    setenv("TART_HOME", temporaryHome.path, 1)
    defer { restoreEnvironment("TART_HOME", value: previousHome) }

    let command = try Run.parse(["vm", "--net-softnet-control-fd", "3"])

    XCTAssertTrue(command.netSoftnet)
    XCTAssertEqual(command.netSoftnetControlFd, 3)
  }

  func testControlFDIsRejectedWithHostNetworking() throws {
    let temporaryHome = try createTemporaryTartHome()
    defer { try? FileManager.default.removeItem(at: temporaryHome) }
    let previousHome = ProcessInfo.processInfo.environment["TART_HOME"]
    setenv("TART_HOME", temporaryHome.path, 1)
    defer { restoreEnvironment("TART_HOME", value: previousHome) }

    XCTAssertThrowsError(
      try Run.parse(["vm", "--net-host", "--net-softnet-control-fd", "3"])
    )
  }

  private func createTemporaryTartHome() throws -> URL {
    let temporaryHome = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let vm = temporaryHome.appendingPathComponent("vms/vm")
    try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)

    for name in ["config.json", "disk.img", "nvram.bin"] {
      XCTAssertTrue(FileManager.default.createFile(atPath: vm.appendingPathComponent(name).path, contents: nil))
    }

    return temporaryHome
  }

  private func restoreEnvironment(_ name: String, value: String?) {
    if let value = value {
      setenv(name, value, 1)
    } else {
      unsetenv(name)
    }
  }
}

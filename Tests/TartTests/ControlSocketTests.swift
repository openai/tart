import NIO
import XCTest
@testable import tart

// Avoid NSObject.bind and Tart's Darwin type shadowing the system function.
private let bindTestSocket = bind

@available(macOS 14, *)
final class ControlSocketTests: XCTestCase {
  func testInitializerCreatesControlSocketBeforeReturning() async throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    let originalDirectory = FileManager.default.currentDirectoryPath
    defer {
      FileManager.default.changeCurrentDirectoryPath(originalDirectory)
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let socketURL = URL(fileURLWithPath: "control.sock", relativeTo: temporaryDirectory)
    var controlSocket: ControlSocket? = try await ControlSocket(socketURL)
    let eventLoopGroup = try XCTUnwrap(controlSocket?.eventLoopGroup)

    do {
      let serverChannel = try XCTUnwrap(controlSocket?.serverChannel)
      XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))

      try await serverChannel.executeThenClose { _ in }
    }

    controlSocket = nil
    try await eventLoopGroup.shutdownGracefully()
  }

  func testInitializerPropagatesControlSocketCreationFailure() async throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    let originalDirectory = FileManager.default.currentDirectoryPath
    defer {
      FileManager.default.changeCurrentDirectoryPath(originalDirectory)
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let socketURL = URL(fileURLWithPath: "missing/control.sock", relativeTo: temporaryDirectory)

    do {
      _ = try await ControlSocket(socketURL)
      XCTFail("Binding should fail when the socket's parent directory does not exist")
    } catch {
      XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }
  }

  func testInitializerReplacesStaleSocketInLongEncodedPath() async throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    let originalDirectory = FileManager.default.currentDirectoryPath
    defer {
      FileManager.default.changeCurrentDirectoryPath(originalDirectory)
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let vmDirectory = temporaryDirectory.appendingPathComponent(
      "Tart Home %# 虚拟机 " + String(repeating: "v", count: 104), isDirectory: true
    )
    try FileManager.default.createDirectory(at: vmDirectory, withIntermediateDirectories: false)
    let socketURL = URL(fileURLWithPath: "control.sock", relativeTo: vmDirectory)
    XCTAssertGreaterThan(socketURL.path.utf8.count, 104)

    // Closing a POSIX socket leaves its path behind, as exiting "tart run" does.
    XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(vmDirectory.path))
    let expectedDirectory = FileManager.default.currentDirectoryPath
    let address = try SocketAddress(unixDomainSocketPath: "control.sock")
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    XCTAssertEqual(address.withSockAddr { bindTestSocket(descriptor, $0, socklen_t($1)) }, 0)
    XCTAssertEqual(close(descriptor), 0)
    XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(originalDirectory))

    var controlSocket: ControlSocket? = try await ControlSocket(socketURL)
    let eventLoopGroup = try XCTUnwrap(controlSocket?.eventLoopGroup)
    do {
      let serverChannel = try XCTUnwrap(controlSocket?.serverChannel)
      XCTAssertEqual(FileManager.default.currentDirectoryPath, expectedDirectory)
      XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
      try await serverChannel.executeThenClose { _ in }
    }
    controlSocket = nil
    try await eventLoopGroup.shutdownGracefully()
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
  }
}

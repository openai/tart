import XCTest
import Foundation
import Network
@testable import tart

final class ARPCacheTests: XCTestCase {
  private let mac = MACAddress(fromString: "00:11:22:33:44:55")!

  private func cache(_ output: String, exitCode: Int = 0) throws -> ARPCache {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let command = directory.appendingPathComponent("arp-fixture")
    let quoted = output.replacingOccurrences(of: "'", with: "'\"'\"'")
    try "#!/bin/sh\nprintf '%s' '\(quoted)'\nexit \(exitCode)\n".write(to: command, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
    return try ARPCache(arpCommandURL: command)
  }

  func testEmptySuccessfulOutputHasNoAddress() throws {
    XCTAssertNil(try cache("").ResolveMACAddress(macAddress: mac))
  }

  func testWhitespaceSuccessfulOutputHasNoAddress() throws {
    for output in ["\n", " \t\r\n", "\n\n"] {
      XCTAssertNil(try cache(output).ResolveMACAddress(macAddress: mac))
    }
  }

  func testEmptyOutputPreservesCommandFailure() throws {
    XCTAssertThrowsError(try cache("", exitCode: 7)) { error in
      XCTAssertEqual((error as? ARPCommandFailedError)?.terminationStatus, 7)
    }
  }

  func testNonemptyOutputPreservesCommandFailure() throws {
    XCTAssertThrowsError(try cache("synthetic failure", exitCode: 9)) { error in
      XCTAssertEqual((error as? ARPCommandFailedError)?.terminationStatus, 9)
    }
  }

  func testValidEntryResolvesAddress() throws {
    let value = try cache("? (192.0.2.8) at 0:11:22:33:44:55 on en0 ifscope [ethernet]\n")
    XCTAssertEqual(try value.ResolveMACAddress(macAddress: mac), IPv4Address("192.0.2.8"))
  }

  func testIncompleteAndOtherEntriesDoNotMatch() throws {
    let value = try cache("""
    ? (192.0.2.9) at (incomplete) on en0 ifscope [ethernet]
    ? (192.0.2.10) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]
    """)
    XCTAssertNil(try value.ResolveMACAddress(macAddress: mac))
  }

  func testMalformedNonemptyOutputStillFails() throws {
    XCTAssertThrowsError(try cache("synthetic invalid entry").ResolveMACAddress(macAddress: mac)) {
      XCTAssertTrue($0 is ARPCommandYieldedInvalidOutputError)
    }
  }

  func testInvalidAddressesStillFail() throws {
    for line in [
      "? (not-an-ip) at 0:11:22:33:44:55 on en0 ifscope [ethernet]",
      "? (192.0.2.8) at not-a-mac on en0 ifscope [ethernet]",
    ] {
      XCTAssertThrowsError(try cache(line).ResolveMACAddress(macAddress: mac)) {
        XCTAssertTrue($0 is ARPCommandYieldedInvalidOutputError)
      }
    }
  }
}

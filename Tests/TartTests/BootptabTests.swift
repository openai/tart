import XCTest
import Network
@testable import tart

final class BootptabTests: XCTestCase {
  func testResolveMACAddress() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    // A missing file produces no Bootptab
    XCTAssertNil(try Bootptab(url))

    // Write reservations with duplicates, conflicts, and a malformed MAC address
    let contents = """
    # DHCP reservations
    %
    client1 1 02:ab:00:01:02:03 192.168.64.2
    client2 1 02:ab:00:01:02:03 192.168.64.2
    client3 1 02:ab:00:01:02:04 192.168.64.3
    client4 1 02:ab:00:01:02:04 192.168.65.3
    malformed 1 02:gg:00:01:02:03 192.168.64.9
    """
    try contents.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    // Parse the reservation file
    let bootptab = try XCTUnwrap(Bootptab(url))

    // Identical reservations resolve to one address
    XCTAssertEqual(try bootptab.ResolveMACAddress(
      macAddress: MACAddress(fromString: "02:ab:00:01:02:03")!), IPv4Address("192.168.64.2"))

    // An unknown MAC address has no reservation
    XCTAssertNil(try bootptab.ResolveMACAddress(
      macAddress: MACAddress(fromString: "02:ab:00:01:02:05")!))

    // Conflicting reservations produce an error
    XCTAssertThrowsError(try bootptab.ResolveMACAddress(
      macAddress: MACAddress(fromString: "02:ab:00:01:02:04")!))
  }
}

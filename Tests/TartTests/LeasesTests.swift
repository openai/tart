import XCTest
@testable import tart

import Network
import SwiftDate

final class LeasesTests: XCTestCase {
  func testNoExpired() throws {
    let macAddress = MACAddress(fromString: "11:22:33:44:55:66")!

    let leases = try Leases("""
    {
      name=whatever
      ip_address=66.66.66.66
      hw_address=1,\(macAddress)
      identifier=1,\(macAddress)
      lease=\(Int((Date() - 1.seconds).timeIntervalSince1970).hex)

    }
    {
      name=whatever
      ip_address=1.2.3.4
      hw_address=1,\(macAddress)
      identifier=1,\(macAddress)
      lease=\(Int((Date() + 10.minutes).timeIntervalSince1970).hex)
    }
    {
      name=whatever
      ip_address=66.66.66.66
      hw_address=1,\(macAddress)
      identifier=1,\(macAddress)
      lease=\(Int((Date() - 1.seconds).timeIntervalSince1970).hex)
    }
    """)

    XCTAssertEqual(IPv4Address("1.2.3.4"), leases.ResolveMACAddress(macAddress: macAddress))
  }

  func testDuplicateYetNotExpiredLeases() throws {
    let macAddress = MACAddress(fromString: "11:22:33:44:55:66")!

    let leases = try Leases("""
    {
            name=debian
            ip_address=192.168.64.1
            hw_address=1,\(macAddress)
            identifier=1,\(macAddress)
            lease=\(Int((Date() + 10.minutes).timeIntervalSince1970).hex)
    }
    {
            name=debian
            ip_address=192.168.64.2
            hw_address=1,\(macAddress)
            identifier=1,\(macAddress)
            lease=\(Int((Date() + 5.minutes).timeIntervalSince1970).hex)
    }
    """)

    XCTAssertEqual(IPv4Address("192.168.64.1"), leases.ResolveMACAddress(macAddress: macAddress))
  }

  func testErrorDescriptions() throws {
    XCTAssertThrowsError(try Leases("}")) { error in
      XCTAssertEqual("\(error)", "unexpected DHCPD leases file format on line 1: unexpected lease block end (})")
    }

    XCTAssertThrowsError(try Leases("{\n  name=debian")) { error in
      XCTAssertEqual("\(error)", "truncated DHCPD leases file")
    }
  }
}

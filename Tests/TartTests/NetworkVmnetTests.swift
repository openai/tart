import XCTest
@testable import tart

#if compiler(>=6.4)
  final class NetworkVmnetTests: XCTestCase {
    func testParsesCanonicalPrivateSubnet() throws {
      let subnet = try IPv4Subnet("192.168.200.0/24")

      XCTAssertEqual(subnet.description, "192.168.200.0/24")
      XCTAssertEqual(subnet.gatewayAddressDescription, "192.168.200.1")
      XCTAssertEqual(subnet.subnetMaskDescription, "255.255.255.0")
    }

    func testAcceptsAllRFC1918Ranges() throws {
      XCTAssertEqual(try IPv4Subnet("10.0.0.0/8").description, "10.0.0.0/8")
      XCTAssertEqual(try IPv4Subnet("172.16.0.0/12").description, "172.16.0.0/12")
      XCTAssertEqual(try IPv4Subnet("192.168.0.0/16").description, "192.168.0.0/16")
    }

    func testAcceptsSmallestUsableSubnet() throws {
      let subnet = try IPv4Subnet("192.168.200.0/30")

      XCTAssertEqual(subnet.gatewayAddressDescription, "192.168.200.1")
      XCTAssertEqual(subnet.subnetMaskDescription, "255.255.255.252")
    }

    func testRejectsNonCanonicalNetworkAddress() {
      XCTAssertThrowsError(try IPv4Subnet("192.168.200.1/24")) { error in
        XCTAssertTrue(String(describing: error).contains("use 192.168.200.0/24"))
      }
    }

    func testRejectsPublicSubnet() {
      XCTAssertThrowsError(try IPv4Subnet("203.0.113.0/24"))
    }

    func testRejectsSubnetExtendingOutsidePrivateRange() {
      XCTAssertThrowsError(try IPv4Subnet("192.168.0.0/15"))
    }

    func testRejectsSubnetWithoutGuestAddress() {
      XCTAssertThrowsError(try IPv4Subnet("192.168.200.0/31"))
      XCTAssertThrowsError(try IPv4Subnet("192.168.200.0/32"))
    }

    func testRejectsMalformedCIDR() {
      XCTAssertThrowsError(try IPv4Subnet("192.168.200.0"))
      XCTAssertThrowsError(try IPv4Subnet("not-an-address/24"))
    }
  }
#endif

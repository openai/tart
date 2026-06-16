import XCTest
@testable import tart

#if compiler(>=6.4)
  @available(macOS 27, *)
  final class NetworkVmnetTests: XCTestCase {
    func testParsesSingleTCPRule() throws {
      let rules = try NetworkVmnet.parsePortForwardings("2222:22")
      XCTAssertEqual(rules, [
        NetworkVmnet.PortForwarding(proto: .tcp, externalPort: 2222, internalPort: 22),
      ])
    }

    func testParsesExplicitProtocols() throws {
      let rules = try NetworkVmnet.parsePortForwardings("8080:80/tcp,5353:53/udp")
      XCTAssertEqual(rules, [
        NetworkVmnet.PortForwarding(proto: .tcp, externalPort: 8080, internalPort: 80),
        NetworkVmnet.PortForwarding(proto: .udp, externalPort: 5353, internalPort: 53),
      ])
    }

    func testProtocolIsCaseInsensitive() throws {
      let rules = try NetworkVmnet.parsePortForwardings("9000:9000/UDP")
      XCTAssertEqual(rules.first?.proto, .udp)
    }

    func testRejectsMissingInternalPort() {
      XCTAssertThrowsError(try NetworkVmnet.parsePortForwardings("2222"))
    }

    func testRejectsZeroPort() {
      XCTAssertThrowsError(try NetworkVmnet.parsePortForwardings("0:22"))
      XCTAssertThrowsError(try NetworkVmnet.parsePortForwardings("2222:0"))
    }

    func testRejectsUnknownProtocol() {
      XCTAssertThrowsError(try NetworkVmnet.parsePortForwardings("2222:22/sctp"))
    }

    func testRejectsOutOfRangePort() {
      XCTAssertThrowsError(try NetworkVmnet.parsePortForwardings("99999:22"))
    }
  }
#endif

import XCTest
@testable import tart

final class VMIdentityServiceTests: XCTestCase {
  private let vmPID: Int32 = 100
  private let helperPID: Int32 = 200
  private let vmID = "11111111-1111-4111-8111-111111111111"
  private let identityID = "22222222-2222-4222-8222-222222222222"

  private var vmFactory: String { "pid/100/\(VMIdentityService.vmService)" }
  private var vmTarget: String { "\(vmFactory).\(vmID)" }
  private var identityFactory: String { "pid/200/\(VMIdentityService.identityService)" }
  private var identityTarget: String { "\(identityFactory).\(identityID)" }

  private func service(_ target: String, parent: Int32, program: String, extra: String) -> String {
    "\(target) = {\n\ttype = XPCService\n\tprogram = \(program)\n\tdomain = pid/\(parent) [process]\n\(extra)\n}\n"
  }

  private func fixtures() -> [String: String] {
    [
      vmFactory: service(vmFactory, parent: vmPID, program: VMIdentityService.vmProgram,
                         extra: "\tinstances = {\n\t\t\(VMIdentityService.vmService).\(vmID),\n\t}"),
      vmTarget: service(vmTarget, parent: vmPID, program: VMIdentityService.vmProgram,
                        extra: "\tstate = running\n\tpid = \(helperPID)"),
      identityFactory: service(identityFactory, parent: helperPID, program: VMIdentityService.identityProgram,
                               extra: "\tinstances = {\n\t\t\(VMIdentityService.identityService).\(identityID),\n\t}"),
      identityTarget: service(identityTarget, parent: helperPID, program: VMIdentityService.identityProgram,
                              extra: "\tstate = running\n\tpid = 300"),
    ]
  }

  private func terminate(_ fixtures: [String: String]) -> [VMIdentityService.Identity] {
    var signals: [VMIdentityService.Identity] = []
    _ = VMIdentityService.terminate(vmPID: vmPID, run: { fixtures[$0[1]] }) { identity in
      signals.append(identity)
      return true
    }
    return signals
  }

  func testTerminatesOnlyTheUUIDQualifiedIdentityService() {
    XCTAssertEqual(terminate(fixtures()), [VMIdentityService.Identity(target: identityTarget, parentPID: helperPID, pid: 300)])
  }

  func testAmbiguousFactoriesFailClosed() {
    for factory in [vmFactory, identityFactory] {
      var data = fixtures()
      data[factory] = data[factory]!.replacingOccurrences(of: "\n\t}", with: "\n\t\tunrelated.00000000-0000-0000-0000-000000000000,\n\t}")
      XCTAssertTrue(terminate(data).isEmpty)
    }
  }

  func testUnexpectedExecutableOrDomainFailsClosed() {
    for target in [vmFactory, vmTarget, identityFactory, identityTarget] {
      for property in ["\tprogram = ", "\tdomain = pid/"] {
        var data = fixtures()
        data[target] = data[target]!.replacingOccurrences(of: property, with: property + "unexpected")
        XCTAssertTrue(terminate(data).isEmpty, "\(target): \(property)")
      }
    }
  }

  func testMissingOrStoppedServicesAreNotSignalled() {
    for target in [vmFactory, vmTarget, identityFactory, identityTarget] {
      var data = fixtures()
      data.removeValue(forKey: target)
      XCTAssertTrue(terminate(data).isEmpty)
    }
    var data = fixtures()
    data[identityTarget] = data[identityTarget]!.replacingOccurrences(of: "state = running", with: "state = not running")
    XCTAssertTrue(terminate(data).isEmpty)
  }

  func testMalformedInstanceIdentifierFailsClosed() {
    var data = fixtures()
    data[identityFactory] = data[identityFactory]!.replacingOccurrences(of: identityID, with: "../other")
    XCTAssertTrue(terminate(data).isEmpty)
  }

  func testCommandDeadline() {
    let start = Date()
    let result = VMIdentityService.run(["10"], deadline: .now() + .milliseconds(50),
                                       executable: URL(fileURLWithPath: "/bin/sleep"))
    XCTAssertNil(result)
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
  }
}

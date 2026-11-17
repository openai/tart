import XCTest
@testable import tart

final class VMIdentityStopTests: XCTestCase {
  private let label = "com.apple.AppleVirtualPlatform.Identity.Virtio.778FA60F-540D-4262-B258-60A2B539891B"

  func testOwnedServiceOnly() {
    let text = "pid/100 = {\n\tservices = {\n\t\t200 - \(label)\n\t}\n\tother = {\n\t\t999 - \(label)\n\t}\n}\n"
    XCTAssertEqual(VMIdentityStop.parse(text, owner: 100)?.pid, 200)
    XCTAssertNil(VMIdentityStop.parse(text, owner: 101))
  }

  func testAmbiguousOrMissingService() {
    XCTAssertNil(VMIdentityStop.parse("pid/100 = {\n\tservices = {\n\t}\n}\n", owner: 100))
    let text = "pid/100 = {\n\tservices = {\n\t\t200 - \(label)\n\t\t201 - \(label)\n\t}\n}\n"
    XCTAssertNil(VMIdentityStop.parse(text, owner: 100))
  }
}

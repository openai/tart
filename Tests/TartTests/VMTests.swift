import XCTest
@testable import tart

final class VMTests: XCTestCase {
  func testVirtualMachineLabelUsesVMName() {
    XCTAssertEqual(VM.virtualMachineLabel(for: "macos-runner"), "macos-runner")
  }

  func testVirtualMachineLabelTrimsWhitespace() {
    XCTAssertEqual(VM.virtualMachineLabel(for: "  macos-runner  "), "macos-runner")
  }

  func testVirtualMachineLabelRejectsWhitespaceOnlyName() {
    XCTAssertNil(VM.virtualMachineLabel(for: "   "))
  }

  func testVirtualMachineLabelCapsAtSixtyFourCharacters() {
    XCTAssertEqual(
      VM.virtualMachineLabel(for: String(repeating: "a", count: 65)),
      String(repeating: "a", count: 64)
    )
  }
}

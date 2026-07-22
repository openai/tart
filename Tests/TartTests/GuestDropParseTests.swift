import XCTest
@testable import tart

final class GuestDropParseTests: XCTestCase {
  func testParsesSimpleLine() {
    XCTAssertEqual(
      GuestDropSynthesis.parseDestinationFolder(stdout: "tartdrop-dest=Desktop\n"),
      "Desktop"
    )
  }

  func testIgnoresBannerLinesAndTakesTheValue() {
    let out = "tart-guest-agent v1.2\nsome diagnostic noise\ntartdrop-dest=Documents\n"
    XCTAssertEqual(GuestDropSynthesis.parseDestinationFolder(stdout: out), "Documents")
  }

  func testLastValueWins() {
    let out = "tartdrop-dest=Old\ntartdrop-dest=New\n"
    XCTAssertEqual(GuestDropSynthesis.parseDestinationFolder(stdout: out), "New")
  }

  func testHandlesCRLF() {
    XCTAssertEqual(
      GuestDropSynthesis.parseDestinationFolder(stdout: "noise\r\ntartdrop-dest=Downloads\r\n"),
      "Downloads"
    )
  }

  func testNoLineReturnsNil() {
    XCTAssertNil(GuestDropSynthesis.parseDestinationFolder(stdout: "just some output\n"))
    XCTAssertNil(GuestDropSynthesis.parseDestinationFolder(stdout: ""))
  }

  func testEmptyValueReturnsNil() {
    XCTAssertNil(GuestDropSynthesis.parseDestinationFolder(stdout: "tartdrop-dest=\n"))
  }

  func testFolderNameWithSpaces() {
    XCTAssertEqual(
      GuestDropSynthesis.parseDestinationFolder(stdout: "tartdrop-dest=My Project\n"),
      "My Project"
    )
  }
}

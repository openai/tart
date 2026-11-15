import Foundation
import XCTest
@testable import tart

final class LivePauseTests: XCTestCase {
  func testCommandsParseVMName() throws {
    XCTAssertEqual(try Pause.parse(["example"]).name, "example")
    XCTAssertEqual(try Resume.parse(["example"]).name, "example")
  }

  func testStalePauseMarkerDoesNotMakeStoppedVMPaused() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = VMDirectory(baseURL: root)
    try Data().write(to: directory.configURL)
    try Data().write(to: directory.pausedURL)
    XCTAssertEqual(try directory.state(), .Stopped)
    try Data().write(to: directory.stateURL)
    XCTAssertEqual(try directory.state(), .Suspended)
  }
}

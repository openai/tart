import Foundation
import XCTest
@testable import tart

final class VMDirectoryLayoutTests: XCTestCase {
  func testStandaloneLayoutWithPinnedManifest() throws {
    let vmDir = try temporaryVMDirectory()

    try touch(vmDir.configURL)
    try touch(vmDir.nvramURL)
    try touch(vmDir.diskURL)
    try touch(vmDir.manifestURL)

    XCTAssertEqual(vmDir.layout, .standalone)
    XCTAssertTrue(vmDir.initialized)
  }

  func testStackedLocalLayout() throws {
    let vmDir = try temporaryVMDirectory()

    try touch(vmDir.configURL)
    try touch(vmDir.nvramURL)
    try touch(vmDir.manifestURL)
    try touch(vmDir.overlayURL)

    XCTAssertEqual(vmDir.layout, .stackedLocal)
    XCTAssertTrue(vmDir.initialized)
  }

  func testStackedOCIRecordLayout() throws {
    let vmDir = try temporaryVMDirectory()

    try touch(vmDir.configURL)
    try touch(vmDir.nvramURL)
    try touch(vmDir.manifestURL)

    XCTAssertEqual(vmDir.layout, .stackedOCIRecord)
    XCTAssertFalse(vmDir.initialized)
  }

  func testAmbiguousDiskAndOverlayIsNotInitialized() throws {
    let vmDir = try temporaryVMDirectory()

    try touch(vmDir.configURL)
    try touch(vmDir.nvramURL)
    try touch(vmDir.diskURL)
    try touch(vmDir.manifestURL)
    try touch(vmDir.overlayURL)

    XCTAssertNil(vmDir.layout)
    XCTAssertFalse(vmDir.initialized)
  }

  private func temporaryVMDirectory() throws -> VMDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }

    return VMDirectory(baseURL: url)
  }

  private func touch(_ url: URL) throws {
    XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
  }
}

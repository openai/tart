import XCTest
@testable import tart

import Virtualization

final class DirectoryShareTests: XCTestCase {
  func testNamedParsing() throws {
    let share = try DirectoryShare(parseFrom: "build:/Users/admin/build")
    XCTAssertEqual(share.name, "build")
    XCTAssertEqual(share.path, URL(filePath: "/Users/admin/build"))
    XCTAssertFalse(share.readOnly)
  }

  func testNamedReadOnlyParsing() throws {
    let share = try DirectoryShare(parseFrom: "build:/Users/admin/build:ro")
    XCTAssertEqual(share.name, "build")
    XCTAssertEqual(share.path, URL(filePath: "/Users/admin/build"))
    XCTAssertTrue(share.readOnly)
  }

  func testOptionalNameParsing() throws {
    let share = try DirectoryShare(parseFrom: "/Users/admin/build")
    XCTAssertNil(share.name)
    XCTAssertEqual(share.path, URL(filePath: "/Users/admin/build"))
    XCTAssertFalse(share.readOnly)
  }

  func testOptionalNameReadOnlyParsing() throws {
    let share = try DirectoryShare(parseFrom: "/Users/admin/build:ro")
    XCTAssertNil(share.name)
    XCTAssertEqual(share.path, URL(filePath: "/Users/admin/build"))
    XCTAssertTrue(share.readOnly)
  }

  func testMountTagParsing() throws {
    let share = try DirectoryShare(parseFrom: "/Users/admin/build:tag=foo-bar")
    XCTAssertNil(share.name)
    XCTAssertEqual(share.path, URL(filePath: "/Users/admin/build"))
    XCTAssertFalse(share.readOnly)
    XCTAssertEqual(share.mountTag, "foo-bar")

    let roShare = try DirectoryShare(parseFrom: "/Users/admin/build:ro,tag=foo-bar")
    XCTAssertNil(roShare.name)
    XCTAssertEqual(roShare.path, URL(filePath: "/Users/admin/build"))
    XCTAssertTrue(roShare.readOnly)
    XCTAssertEqual(roShare.mountTag, "foo-bar")

    let inverseRoShare = try DirectoryShare(parseFrom: "/Users/admin/build:tag=foo-bar,ro")
    XCTAssertNil(inverseRoShare.name)
    XCTAssertEqual(inverseRoShare.path, URL(filePath: "/Users/admin/build"))
    XCTAssertTrue(inverseRoShare.readOnly)
    XCTAssertEqual(inverseRoShare.mountTag, "foo-bar")
  }

  func testURL() throws {
    let archiveWithoutNameOrOptions = try DirectoryShare(parseFrom: "https://example.com/archive.tar.gz")
    XCTAssertNil(archiveWithoutNameOrOptions.name)
    XCTAssertEqual(archiveWithoutNameOrOptions.path, URL(string: "https://example.com/archive.tar.gz")!)
    XCTAssertFalse(archiveWithoutNameOrOptions.readOnly)
    XCTAssertEqual(archiveWithoutNameOrOptions.mountTag, VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)

    let archiveWithOptions = try DirectoryShare(parseFrom: "https://example.com/archive.tar.gz:ro,tag=sometag")
    XCTAssertNil(archiveWithOptions.name)
    XCTAssertEqual(archiveWithOptions.path, URL(string: "https://example.com/archive.tar.gz")!)
    XCTAssertTrue(archiveWithOptions.readOnly)
    XCTAssertEqual(archiveWithOptions.mountTag, "sometag")

    let archiveWithNameAndOptions = try DirectoryShare(parseFrom: "somename:https://example.com/archive.tar.gz:ro,tag=sometag")
    XCTAssertEqual(archiveWithNameAndOptions.name, "somename")
    XCTAssertEqual(archiveWithNameAndOptions.path, URL(string: "https://example.com/archive.tar.gz")!)
    XCTAssertTrue(archiveWithNameAndOptions.readOnly)
    XCTAssertEqual(archiveWithNameAndOptions.mountTag, "sometag")

    let httpArchiveWithName = try DirectoryShare(parseFrom: "somename:http://example.com/archive.tar.gz")
    XCTAssertEqual(httpArchiveWithName.name, "somename")
    XCTAssertEqual(httpArchiveWithName.path, URL(string: "http://example.com/archive.tar.gz")!)
  }
}

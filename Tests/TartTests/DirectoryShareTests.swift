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

  func testProgrammaticInit() throws {
    let url = URL(filePath: "/tmp/dropzone-test")
    let share = DirectoryShare(name: "Dropped Files", path: url, readOnly: false, mountTag: "test-tag")
    XCTAssertEqual(share.name, "Dropped Files")
    XCTAssertEqual(share.path, url)
    XCTAssertFalse(share.readOnly)
    XCTAssertEqual(share.mountTag, "test-tag")
  }

  func testCollectWithoutDropZone() throws {
    let shares = try DirectoryShare.collect(dirArgs: ["build:/Users/admin/build"])
    XCTAssertEqual(shares.count, 1)
    XCTAssertEqual(shares[0].name, "build")
  }

  func testCollectEmptyWithoutDropZone() throws {
    let shares = try DirectoryShare.collect(dirArgs: [])
    XCTAssertTrue(shares.isEmpty)
  }

  func testCollectWithDropZoneOnly() throws {
    let url = URL(filePath: "/tmp/dropzone-test")
    let shares = try DirectoryShare.collect(dirArgs: [], dropZoneURL: url)
    XCTAssertEqual(shares.count, 1)
    XCTAssertEqual(shares[0].name, "Dropped Files")
    XCTAssertEqual(shares[0].path, url)
    XCTAssertFalse(shares[0].readOnly)
    XCTAssertEqual(shares[0].mountTag, VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
  }

  func testCollectWithDropZoneAndNamedDirs() throws {
    let url = URL(filePath: "/tmp/dropzone-test")
    let shares = try DirectoryShare.collect(
      dirArgs: ["src:/Users/admin/src", "build:/Users/admin/build:ro"],
      dropZoneURL: url
    )
    XCTAssertEqual(shares.count, 3)
    XCTAssertEqual(shares[0].name, "src")
    XCTAssertEqual(shares[1].name, "build")
    XCTAssertTrue(shares[1].readOnly)
    XCTAssertEqual(shares[2].name, "Dropped Files")
    XCTAssertEqual(shares[2].path, url)
  }

  // When --dir is unnamed and drag-and-drop is on, both shares end up on the
  // automount tag — collection succeeds but the downstream sharing-device
  // builder will reject the combination with a clearer error than before.
  func testCollectWithDropZoneAndUnnamedDir() throws {
    let url = URL(filePath: "/tmp/dropzone-test")
    let shares = try DirectoryShare.collect(
      dirArgs: ["/Users/admin/build"],
      dropZoneURL: url
    )
    XCTAssertEqual(shares.count, 2)
    XCTAssertNil(shares[0].name)
    XCTAssertEqual(shares[1].name, "Dropped Files")
  }

  // An unnamed --dir with an explicit non-default mount tag is on a different
  // device from the drop zone, so it doesn't conflict.
  func testCollectWithDropZoneAndUnnamedDirOnCustomTag() throws {
    let url = URL(filePath: "/tmp/dropzone-test")
    let shares = try DirectoryShare.collect(
      dirArgs: ["/Users/admin/build:tag=custom"],
      dropZoneURL: url
    )
    XCTAssertEqual(shares.count, 2)
    XCTAssertNil(shares[0].name)
    XCTAssertEqual(shares[0].mountTag, "custom")
    XCTAssertEqual(shares[1].name, "Dropped Files")
    XCTAssertEqual(shares[1].mountTag, VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
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
  }
}

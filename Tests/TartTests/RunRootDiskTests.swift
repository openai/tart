import Foundation
import ArgumentParser
import XCTest
@testable import tart

final class RunRootDiskTests: XCTestCase {
  func testRootDiskIsOptional() throws {
    XCTAssertNil(try Run.rootDiskNBDURL(nil, DiskOptions("")))
  }

  func testRootDiskAcceptsNBDSchemes() throws {
    for url in [
      "nbd://example.com:10809/disk",
      "nbds://example.com:10809/disk",
      "nbd+unix:///disk?socket=/tmp/disk.sock",
      "nbds+unix:///disk?socket=/tmp/disk.sock",
      " NBD+UNIX:///disk?socket=/tmp/disk.sock ",
    ] {
      let parsed = try XCTUnwrap(Run.rootDiskNBDURL(url, DiskOptions("")), url)
      XCTAssertEqual(parsed.absoluteString, url.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  func testRootDiskRejectsNonNBDURLs() {
    for url in ["", "/tmp/disk.img", "file:///tmp/disk.img", "https://example.com/disk"] {
      XCTAssertThrowsError(try Run.rootDiskNBDURL(url, DiskOptions("")), url) { error in
        XCTAssertTrue(Run.message(for: error).contains("must be an NBD URL"), url)
      }
    }
  }

  func testRootDiskAcceptsNBDOptions() throws {
    for options in ["ro", "sync=none", "sync=full", "ro,sync=none"] {
      XCTAssertNotNil(try Run.rootDiskNBDURL("nbd://localhost/disk", DiskOptions(options)), options)
    }
  }

  func testRootDiskRejectsDiskImageOnlyOptions() {
    for options in ["caching=cached", "caching=automatic", "sync=fsync", "sync=bogus"] {
      XCTAssertThrowsError(try Run.rootDiskNBDURL("nbd://localhost/disk", DiskOptions(options)), options)
    }
  }

  func testRunParsesRootDisk() throws {
    try withTemporaryVM { _ in
      let command = try Run.parseAsRoot([
        "vm", "--root-disk", "nbd+unix:///disk?socket=/tmp/disk.sock", "--root-disk-opts", "ro,sync=none",
      ]) as! Run

      XCTAssertEqual(command.rootDisk, "nbd+unix:///disk?socket=/tmp/disk.sock")
      XCTAssertEqual(command.rootDiskOpts, "ro,sync=none")
    }
  }

  func testRunRejectsInvalidRootDiskDuringValidation() throws {
    try withTemporaryVM { _ in
      XCTAssertThrowsError(try Run.parseAsRoot(["vm", "--root-disk", "/tmp/disk.img"]))
      XCTAssertThrowsError(try Run.parseAsRoot([
        "vm", "--root-disk", "nbd://localhost/disk", "--root-disk-opts", "caching=cached",
      ]))
    }
  }

  #if arch(arm64)
    func testRunRejectsRootDiskWithSuspendable() throws {
      try withTemporaryVM { _ in
        XCTAssertThrowsError(try Run.parseAsRoot(["vm", "--suspendable", "--root-disk", "nbd://localhost/disk"])) { error in
          XCTAssertTrue(Run.message(for: error).contains("--root-disk cannot be used with --suspendable"))
        }
      }
    }
  #endif

  func testRunRejectsRootDiskWhenResumingSuspendedVM() throws {
    try withTemporaryVM { vmDir in
      XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.stateURL.path, contents: Data()))

      XCTAssertThrowsError(try Run.parseAsRoot(["vm", "--root-disk", "nbd://localhost/disk"])) { error in
        XCTAssertTrue(Run.message(for: error).contains("to resume a suspended VM"))
      }
    }
  }

  private func withTemporaryVM(_ body: (VMDirectory) throws -> Void) throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: home) }

    let previousHome = ProcessInfo.processInfo.environment["TART_HOME"]
    setenv("TART_HOME", home.path, 1)
    defer {
      if let previousHome {
        setenv("TART_HOME", previousHome, 1)
      } else {
        unsetenv("TART_HOME")
      }
    }

    let vmDir = try VMStorageLocal().create("vm")
    try VMConfig(platform: Linux(), cpuCountMin: 2, memorySizeMin: 512 * 1024 * 1024).save(toURL: vmDir.configURL)
    XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.nvramURL.path, contents: Data()))
    XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.diskURL.path, contents: Data()))

    try body(vmDir)
  }
}

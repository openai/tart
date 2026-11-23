import XCTest
@testable import tart

final class BinaryPathTests: XCTestCase {
  func testSkipsNonExecutableFilesAndDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let plain = root.appendingPathComponent("plain")
    let directory = root.appendingPathComponent("directory")
    let executable = root.appendingPathComponent("executable")
    for parent in [plain, directory, executable] {
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }

    let name = "test-helper"
    try "not executable".write(to: plain.appendingPathComponent(name), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.appendingPathComponent(name).path)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: false)
    let helper = executable.appendingPathComponent(name)
    try "#!/bin/sh\nexit 0\n".write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

    let previousPath = ProcessInfo.processInfo.environment["PATH"]
    setenv("PATH", [plain, directory, executable].map(\.path).joined(separator: ":"), 1)
    defer {
      if let previousPath {
        setenv("PATH", previousPath, 1)
      } else {
        unsetenv("PATH")
      }
    }

    XCTAssertEqual(resolveBinaryPath(name), helper)
    let alias = plain.appendingPathComponent(name)
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: helper)
    XCTAssertEqual(resolveBinaryPath(name), alias)
    try FileManager.default.removeItem(at: helper)
    XCTAssertNil(resolveBinaryPath(name))
  }
}

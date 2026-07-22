import XCTest
@testable import tart

final class ControlSocketURLTests: XCTestCase {
  func testControlSocketURLResolvesToAbsolutePath() throws {
    let baseURL = URL(fileURLWithPath: "/Users/test/.tart/vms/myvm/")
    let vmDir = VMDirectory(baseURL: baseURL)

    // The .path property resolves relative URLs to absolute paths,
    // which is required for stale socket cleanup in ControlSocket.run()
    // since it happens before the working directory is changed.
    XCTAssertEqual(
      vmDir.controlSocketURL.path,
      "/Users/test/.tart/vms/myvm/control.sock"
    )
  }

  func testControlSocketURLRelativePathIsJustFilename() throws {
    let baseURL = URL(fileURLWithPath: "/Users/test/.tart/vms/myvm/")
    let vmDir = VMDirectory(baseURL: baseURL)

    // The .relativePath is used for socket binding after cwd is changed
    XCTAssertEqual(
      vmDir.controlSocketURL.relativePath,
      "control.sock"
    )
  }
}

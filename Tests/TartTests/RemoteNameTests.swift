import XCTest
@testable import tart

final class RemoteNameTests: XCTestCase {
  func testTag() throws {
    let expectedRemoteName = RemoteName(host: "ghcr.io", namespace: "a/b", reference: Reference(tag: "latest"))

    XCTAssertEqual(expectedRemoteName, try RemoteName("ghcr.io/a/b:latest"))
  }

  func testComplexTag() throws {
    let expectedRemoteName = RemoteName(host: "ghcr.io", namespace: "a/b", reference: Reference(tag: "1.2.3-RC-1"))

    XCTAssertEqual(expectedRemoteName, try RemoteName("ghcr.io/a/b:1.2.3-RC-1"))
  }

  func testDigest() throws {
    let expectedRemoteName = RemoteName(
      host: "ghcr.io",
      namespace: "a/b",
      reference: Reference(digest: "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    )

    XCTAssertEqual(expectedRemoteName,
                   try RemoteName("ghcr.io/a/b@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
  }

  func testASCIIOnly() throws {
    // Only ASCII letters are supported
    XCTAssertEqual(try? RemoteName("touché.fr/a/b:latest"), nil)
    XCTAssertEqual(try? RemoteName("ghcr.io/tou/ché:latest"), nil)
    XCTAssertEqual(try? RemoteName("ghcr.io/a/b:touché"), nil)

    // Same as above, but with "é" decomposed into "e" and a combining acute accent
    XCTAssertEqual(try? RemoteName("ghcr.io/a/b:touche\u{301}"), nil)
  }

  func testLocal() throws {
    // Local image names (those that don't include a registry) are not supported
    XCTAssertEqual(try? RemoteName("debian:latest"), nil)
  }

  func testPort() throws {
    // Port is included in host
    XCTAssertEqual(try RemoteName("127.0.0.1:8080/a/b").host, "127.0.0.1:8080")

    // Port must be specified when ":" is used
    XCTAssertEqual(try? RemoteName("127.0.0.1:/a/b").host, nil)
  }

  func testNoPathTraversal() throws {
    XCTAssertEqual(try? RemoteName("ghcr.io/a/../b/c:latest"), nil)
  }
}

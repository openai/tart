import Foundation
import XCTest
@testable import tart

final class ContentStoreTests: XCTestCase {
  func testCreatesDigestDirectoryDuringInitialization() throws {
    let store = try temporaryStore()
    let contentURL = try store.contentURL(for: Digest.hash(Data()))

    XCTAssertTrue(FileManager.default.fileExists(atPath: contentURL.deletingLastPathComponent().path))
  }

  func testInstallAndValidatedLookup() throws {
    let store = try temporaryStore()
    let data = Data("base disk".utf8)
    let digest = Digest.hash(data)
    let temporaryURL = try store.temporaryContentURL(for: digest)
    try data.write(to: temporaryURL)

    let installedURL = try store.install(temporaryURL, contentDigest: digest)

    XCTAssertEqual(installedURL, try store.contentURL(for: digest))
    XCTAssertEqual(try store.existingContentURL(for: digest), installedURL)
  }

  func testCorruptCacheEntryIsMiss() throws {
    let store = try temporaryStore()
    let expectedDigest = Digest.hash(Data("expected".utf8))
    let contentURL = try store.contentURL(for: expectedDigest)
    try FileManager.default.createDirectory(at: contentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("corrupt".utf8).write(to: contentURL)

    XCTAssertNil(try store.existingContentURL(for: expectedDigest))
  }

  func testInstallRejectsWrongContentDigest() throws {
    let store = try temporaryStore()
    let expectedDigest = Digest.hash(Data("expected".utf8))
    let temporaryURL = try store.temporaryContentURL(for: expectedDigest)
    try Data("actual".utf8).write(to: temporaryURL)

    XCTAssertThrowsError(try store.install(temporaryURL, contentDigest: expectedDigest)) { error in
      guard case ContentStoreError.contentDigestMismatch(let expected, _) = error else {
        return XCTFail("unexpected error: \(error)")
      }

      XCTAssertEqual(expected, expectedDigest)
    }
  }

  func testRejectsNonCanonicalDigest() throws {
    let store = try temporaryStore()

    XCTAssertThrowsError(try store.contentURL(for: "sha256:ABC")) { error in
      XCTAssertEqual(error as? ContentStoreError, .invalidContentDigest("sha256:ABC"))
    }
  }

  private func temporaryStore() throws -> ContentStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }

    return try ContentStore(baseURL: url)
  }
}

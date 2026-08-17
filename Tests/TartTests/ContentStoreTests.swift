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
    XCTAssertEqual(try store.contentURLIfPresent(for: expectedDigest), contentURL)
  }

  func testResumableAndLockURLsAreStablePerDigest() throws {
    let store = try temporaryStore()
    let firstDigest = Digest.hash(Data("first".utf8))
    let secondDigest = Digest.hash(Data("second".utf8))

    XCTAssertEqual(
      try store.resumableContentURL(for: firstDigest),
      try store.resumableContentURL(for: firstDigest)
    )
    XCTAssertNotEqual(
      try store.resumableContentURL(for: firstDigest),
      try store.resumableContentURL(for: secondDigest)
    )
    XCTAssertEqual(
      try store.lockURL(for: firstDigest),
      try store.lockURL(for: firstDigest)
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: try store.lockURL(for: firstDigest).path))
  }

  func testInstallReplacesCorruptEntry() throws {
    let store = try temporaryStore()
    let data = Data("expected".utf8)
    let digest = Digest.hash(data)
    let contentURL = try store.contentURL(for: digest)
    try FileManager.default.createDirectory(at: contentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("corrupt".utf8).write(to: contentURL)
    let temporaryURL = try store.temporaryContentURL(for: digest)
    try data.write(to: temporaryURL)

    XCTAssertEqual(try store.install(temporaryURL, contentDigest: digest), contentURL)
    XCTAssertEqual(try Digest.hash(contentURL), digest)
  }

  func testInstallPreservesExistingValidEntry() throws {
    let store = try temporaryStore()
    let data = Data("expected".utf8)
    let digest = Digest.hash(data)
    let firstTemporaryURL = try store.temporaryContentURL(for: digest)
    try data.write(to: firstTemporaryURL)
    let installedURL = try store.install(firstTemporaryURL, contentDigest: digest)
    let secondTemporaryURL = try store.temporaryContentURL(for: digest)
    try data.write(to: secondTemporaryURL)

    XCTAssertEqual(try store.install(secondTemporaryURL, contentDigest: digest), installedURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: secondTemporaryURL.path))
    XCTAssertEqual(try Digest.hash(installedURL), digest)
  }

  func testConcurrentInstallsAcceptDigestValidWinner() throws {
    try assertConcurrentInstalls(seedCorruptEntry: false)
  }

  func testConcurrentInstallsRepairCorruptEntry() throws {
    try assertConcurrentInstalls(seedCorruptEntry: true)
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

  func testContentURLUnderArbitraryRootHasNoSideEffects() throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: rootURL)
    }
    let digest = Digest.hash(Data("content".utf8))

    let contentStore = try temporaryStore()
    let contentURL = try contentStore.contentURL(for: digest, under: rootURL)

    XCTAssertEqual(
      contentURL,
      rootURL.appendingPathComponent("sha256", isDirectory: true)
        .appendingPathComponent(String(digest.dropFirst("sha256:".count)))
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
  }

  private func temporaryStore() throws -> ContentStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }

    return try ContentStore(baseURL: url)
  }

  private func assertConcurrentInstalls(seedCorruptEntry: Bool) throws {
    let store = try temporaryStore()
    let data = Data("expected".utf8)
    let digest = Digest.hash(data)
    let contentURL = try store.contentURL(for: digest)
    try FileManager.default.createDirectory(at: contentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if seedCorruptEntry {
      try Data("corrupt".utf8).write(to: contentURL)
    }

    let temporaryURLs = try (0..<16).map { _ in
      let url = try store.temporaryContentURL(for: digest)
      try data.write(to: url)
      return url
    }
    let errors = ErrorCollector()

    DispatchQueue.concurrentPerform(iterations: temporaryURLs.count) { index in
      do {
        _ = try store.install(temporaryURLs[index], contentDigest: digest)
      } catch {
        errors.append(error)
      }
    }

    XCTAssertTrue(errors.values.isEmpty, "unexpected install errors: \(errors.values)")
    XCTAssertEqual(try Digest.hash(contentURL), digest)
    XCTAssertTrue(temporaryURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
  }

  private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []

    var values: [Error] {
      lock.lock()
      defer { lock.unlock() }
      return errors
    }

    func append(_ error: Error) {
      lock.lock()
      defer { lock.unlock() }
      errors.append(error)
    }
  }
}

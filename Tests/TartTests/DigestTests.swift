import Foundation
import XCTest
@testable import tart

final class DigestTests: XCTestCase {
  func testEmptyData() throws {
    let data = Data("".utf8)

    let digest = Digest()
    digest.update(data)
    XCTAssertEqual(digest.finalize(), "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

    XCTAssertEqual(Digest.hash(data), "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  }

  func testNonEmptyData() throws {
    let data = Data("The quick brown fox jumps over the lazy dog".utf8)

    let digest = Digest()
    digest.update(data)
    XCTAssertEqual(digest.finalize(), "sha256:d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")

    XCTAssertEqual(Digest.hash(data), "sha256:d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
  }

  func testFileAndRangeHashingMatchDataHashing() throws {
    let prefix = Data(repeating: 0x61, count: 4 * 1024 * 1024 + 17)
    let range = Data("range".utf8)
    let suffix = Data(repeating: 0x62, count: 23)
    let data = prefix + range + suffix
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertEqual(try Digest.hash(url), Digest.hash(data))
    XCTAssertEqual(try Digest.hash(url, offset: UInt64(prefix.count), size: UInt64(range.count)), Digest.hash(range))
  }

  func testRangeHashingRejectsOutOfBoundsRanges() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("range".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertThrowsError(try Digest.hash(url, offset: 6, size: 0)) { error in
      guard case DigestError.InvalidOffset = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    XCTAssertThrowsError(try Digest.hash(url, offset: 1, size: UInt64.max)) { error in
      guard case DigestError.InvalidSize = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }
}

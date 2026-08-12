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

  func testFileHashingReadsMultipleChunks() throws {
    let data = Data(repeating: 0xab, count: Digest.fileReadChunkSize + 1)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertEqual(try Digest.hash(url), Digest.hash(data))
  }
}

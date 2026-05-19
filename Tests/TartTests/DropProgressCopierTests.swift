import XCTest
@testable import tart

final class DropProgressCopierTests: XCTestCase {
  private var tmp: URL!

  override func setUpWithError() throws {
    tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("droptest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    addTeardownBlock { [tmp] in
      try? FileManager.default.removeItem(at: tmp!)
    }
  }

  private func write(_ name: String, _ bytes: Int) throws -> URL {
    let url = tmp.appendingPathComponent(name)
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return url
  }

  func testCopiesRegularFileAndReportsFinalProgress() throws {
    let src = try write("src.bin", 3 * 1024 * 1024 + 7)
    let dst = tmp.appendingPathComponent("out.bin")
    var last: Int64 = -1
    try DropProgressCopier.copyTree(
      from: src, to: dst, totalBytes: 0, token: DropCancellationToken()
    ) { last = $0 }

    XCTAssertEqual(last, 3 * 1024 * 1024 + 7, "final callback must report the full size")
    XCTAssertEqual(
      try Data(contentsOf: dst).count, 3 * 1024 * 1024 + 7
    )
  }

  func testReplacesExistingDestination() throws {
    let src = try write("src.bin", 128)
    let dst = tmp.appendingPathComponent("out.bin")
    try Data(repeating: 0x42, count: 999).write(to: dst)  // stale, larger

    try DropProgressCopier.copyTree(
      from: src, to: dst, totalBytes: 0, token: DropCancellationToken()
    ) { _ in }

    XCTAssertEqual(try Data(contentsOf: dst), Data(repeating: 0x41, count: 128))
  }

  func testEmptyFileStillFiresFinalProgress() throws {
    let src = try write("empty.bin", 0)
    let dst = tmp.appendingPathComponent("out.bin")
    var calls = 0
    var last: Int64 = -1
    try DropProgressCopier.copyTree(
      from: src, to: dst, totalBytes: 0, token: DropCancellationToken()
    ) { calls += 1; last = $0 }

    XCTAssertGreaterThanOrEqual(calls, 1)
    XCTAssertEqual(last, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
  }

  func testCancellationThrowsAndRemovesPartial() throws {
    let src = try write("src.bin", 8 * 1024 * 1024)
    let dst = tmp.appendingPathComponent("out.bin")
    let token = DropCancellationToken()
    token.cancel()

    XCTAssertThrowsError(
      try DropProgressCopier.copyTree(
        from: src, to: dst, totalBytes: 0, token: token
      ) { _ in }
    ) { error in
      XCTAssertTrue(error is DropCopyCancelled)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: dst.path),
      "a cancelled copy must not leave a partial file in the drop zone"
    )
  }

  func testErrorRemovesPartialDestination() throws {
    let missing = tmp.appendingPathComponent("does-not-exist.bin")
    let dst = tmp.appendingPathComponent("out.bin")

    XCTAssertThrowsError(
      try DropProgressCopier.copyTree(
        from: missing, to: dst, totalBytes: 0, token: DropCancellationToken()
      ) { _ in }
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: dst.path),
      "a failed copy must not leave a half-written file visible to the guest"
    )
  }

  func testCopiesDirectoryTreeRecursively() throws {
    let srcDir = tmp.appendingPathComponent("bundle", isDirectory: true)
    let sub = srcDir.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 10).write(to: srcDir.appendingPathComponent("a.txt"))
    try Data(repeating: 0x41, count: 20).write(to: sub.appendingPathComponent("b.txt"))

    XCTAssertEqual(DropProgressCopier.totalSize(of: srcDir), 30)

    let dst = tmp.appendingPathComponent("bundle-copy", isDirectory: true)
    var last: Int64 = -1
    try DropProgressCopier.copyTree(
      from: srcDir, to: dst, totalBytes: 30, token: DropCancellationToken()
    ) { last = $0 }

    XCTAssertEqual(last, 30)
    XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("a.txt")).count, 10)
    XCTAssertEqual(
      try Data(contentsOf: dst.appendingPathComponent("Contents/b.txt")).count, 20
    )
  }

  func testTotalSizeOfRegularFile() throws {
    let src = try write("sized.bin", 4242)
    XCTAssertEqual(DropProgressCopier.totalSize(of: src), 4242)
  }
}

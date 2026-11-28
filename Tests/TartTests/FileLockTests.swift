import XCTest
@testable import tart

final class FileLockTests: XCTestCase {
  func testSimple() throws {
    // Create a temporary file that will be used as a lock
    let url = temporaryFile()

    // Make sure this file can be locked and unlocked
    let lock = try FileLock(lockURL: url)
    try lock.lock()
    try lock.unlock()
  }

  func testDoubleLockResultsInError() throws {
    // Create a temporary file that will be used as a lock
    let url = temporaryFile()

    // Create two locks on a same file and ensure one of them fails
    let firstLock = try FileLock(lockURL: url)
    try firstLock.lock()

    let secondLock = try! FileLock(lockURL: url)
    XCTAssertFalse(try secondLock.trylock())
  }

  func testMissingFileResultsInError() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)

    XCTAssertThrowsError(try FileLock(lockURL: url)) { error in
      XCTAssertEqual(error as? FileLockError, .Failed("failed to open lock file \(url): No such file or directory"))
    }
  }

  private func temporaryFile() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)

    FileManager.default.createFile(atPath: url.path, contents: nil)

    return url
  }
}

import XCTest
@testable import tart

final class URLAccessDateTests: XCTestCase {
  func testUpdateAccessDatePreservesModificationDate() throws {
    // Create a temporary file
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    var tmpFile = tmpDir.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: tmpFile.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    // Ensure its access date is different from our desired access date
    let accessDate = Date.init(year: 2008, month: 09, day: 28, hour: 23, minute: 15)
    let modificationDate = Date(timeIntervalSince1970: 1_577_836_800.125)
    try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: tmpFile.path)
    XCTAssertNotEqual(accessDate, try tmpFile.accessDate())

    // Set our desired access date for a file
    try tmpFile.updateAccessDate(accessDate)

    // Ensure the access date has changed to our value
    tmpFile.removeCachedResourceValue(forKey: .contentAccessDateKey)
    XCTAssertEqual(accessDate, try tmpFile.accessDate())

    // Ensure the modification date has not changed
    tmpFile.removeCachedResourceValue(forKey: .contentModificationDateKey)
    let attrs = try tmpFile.resourceValues(forKeys: [.contentModificationDateKey])
    XCTAssertEqual(modificationDate, try XCTUnwrap(attrs.contentModificationDate))
  }
}

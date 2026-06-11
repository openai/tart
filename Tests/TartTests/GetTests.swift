import XCTest
import Foundation
@testable import tart

final class GetTests: XCTestCase {
  func testGetJSONKeepsDiskAsIntegerGBAndSizeAsThreeDecimalGBString() throws {
    let info = GetVMInfo(
      OS: .linux,
      CPU: 4,
      Memory: 8192,
      diskBytes: 51_400_000_000,
      DiskFormat: "raw",
      sizeBytes: 17_234_000_000,
      Display: "1024x768",
      Running: false,
      State: "stopped"
    )

    let json = Format.json.renderSingle(info)
    let data = try XCTUnwrap(json.data(using: .utf8))
    let vmInfo = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(vmInfo["Disk"] as? Int, 51)
    XCTAssertEqual(vmInfo["Size"] as? String, "17.234")
  }

  func testGetTextUsesHumanReadableDiskAndSize() throws {
    let info = GetVMInfo(
      OS: .linux,
      CPU: 4,
      Memory: 8192,
      diskBytes: 51_400_000_000,
      DiskFormat: "raw",
      sizeBytes: 17_200_000_000,
      Display: "1024x768",
      Running: false,
      State: "stopped"
    )

    let text = Format.text.renderSingle(info.textInfo)

    XCTAssertTrue(text.contains("Disk"))
    XCTAssertTrue(text.contains("Size"))
    XCTAssertTrue(text.contains(ByteCountFormatter.string(fromByteCount: 51_400_000_000, countStyle: .file)))
    XCTAssertTrue(text.contains(ByteCountFormatter.string(fromByteCount: 17_200_000_000, countStyle: .file)))
  }
}

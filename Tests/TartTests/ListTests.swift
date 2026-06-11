import XCTest
import Foundation
@testable import tart

final class ListTests: XCTestCase {
  func testListJSONKeepsDiskAndSizeAsIntegerGB() throws {
    let info = ListVMInfo(
      Source: "local",
      Name: "test",
      diskBytes: 51_400_000_000,
      sizeBytes: 17_200_000_000,
      Accessed: "2026-06-11T00:00:00Z",
      Running: false,
      State: "stopped"
    )

    let json = Format.json.renderList([info])
    let data = try XCTUnwrap(json.data(using: .utf8))
    let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let vmInfo = try XCTUnwrap(decoded.first)

    XCTAssertEqual(vmInfo["Disk"] as? Int, 51)
    XCTAssertEqual(vmInfo["Size"] as? Int, 17)
  }

  func testListTextUsesHumanReadableDiskAndSize() throws {
    let info = ListVMInfo(
      Source: "local",
      Name: "test",
      diskBytes: 51_400_000_000,
      sizeBytes: 17_200_000_000,
      Accessed: "1 second ago",
      Running: false,
      State: "stopped"
    )

    let text = Format.text.renderList([info.textInfo])

    XCTAssertTrue(text.contains("Disk"))
    XCTAssertTrue(text.contains("Size"))
    XCTAssertTrue(text.contains(ByteCountFormatter.string(fromByteCount: 51_400_000_000, countStyle: .file)))
    XCTAssertTrue(text.contains(ByteCountFormatter.string(fromByteCount: 17_200_000_000, countStyle: .file)))
  }
}

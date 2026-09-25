import Foundation
import XCTest
@testable import tart

final class HumanReadableByteCountTests: XCTestCase {
  func testUnknownByteCount() throws {
    let unknown = HumanReadableByteCount(nil) { $0 / 1000 / 1000 / 1000 }

    XCTAssertEqual(unknown.description, "-")
    XCTAssertEqual(String(data: try JSONEncoder().encode(unknown), encoding: .utf8), "null")
  }

  func testTextAndJSONRepresentations() throws {
    let integer = HumanReadableByteCount(51_400_000_000) { _ in 51 }
    let string = HumanReadableByteCount(17_234_000_000) { _ in "17.234" }
    let encoder = JSONEncoder()

    XCTAssertEqual(string.description.compactMap(\.wholeNumberValue), [1, 7])
    XCTAssertEqual(try JSONDecoder().decode(Int.self, from: encoder.encode(integer)), 51)
    XCTAssertEqual(try JSONDecoder().decode(String.self, from: encoder.encode(string)), "17.234")
  }
}

import XCTest
@testable import tart

final class DropGeometryTests: XCTestCase {
  func testTopLeftOfUnflippedView() throws {
    // Bottom-up view: a point at (0, viewHeight) is the top-left corner.
    let point = DropGeometry.normalize(
      point: CGPoint(x: 0, y: 1000),
      inViewBoundsSize: CGSize(width: 1280, height: 1000),
      isViewFlipped: false
    )
    XCTAssertEqual(point.x, 0, accuracy: 0.0001)
    XCTAssertEqual(point.y, 0, accuracy: 0.0001)
  }

  func testBottomRightOfUnflippedView() throws {
    let point = DropGeometry.normalize(
      point: CGPoint(x: 1280, y: 0),
      inViewBoundsSize: CGSize(width: 1280, height: 1000),
      isViewFlipped: false
    )
    XCTAssertEqual(point.x, 1, accuracy: 0.0001)
    XCTAssertEqual(point.y, 1, accuracy: 0.0001)
  }

  func testCenterOfUnflippedView() throws {
    let point = DropGeometry.normalize(
      point: CGPoint(x: 640, y: 500),
      inViewBoundsSize: CGSize(width: 1280, height: 1000),
      isViewFlipped: false
    )
    XCTAssertEqual(point.x, 0.5, accuracy: 0.0001)
    XCTAssertEqual(point.y, 0.5, accuracy: 0.0001)
  }

  func testTopLeftOfFlippedView() throws {
    // Flipped view: y increases downward, so (0, 0) is already top-left.
    let point = DropGeometry.normalize(
      point: CGPoint(x: 0, y: 0),
      inViewBoundsSize: CGSize(width: 1280, height: 1000),
      isViewFlipped: true
    )
    XCTAssertEqual(point.x, 0, accuracy: 0.0001)
    XCTAssertEqual(point.y, 0, accuracy: 0.0001)
  }

  func testBottomRightOfFlippedView() throws {
    let point = DropGeometry.normalize(
      point: CGPoint(x: 1280, y: 1000),
      inViewBoundsSize: CGSize(width: 1280, height: 1000),
      isViewFlipped: true
    )
    XCTAssertEqual(point.x, 1, accuracy: 0.0001)
    XCTAssertEqual(point.y, 1, accuracy: 0.0001)
  }

  // The guest agent expects coordinates in [0, 1]; out-of-bounds points (which
  // AppKit can occasionally deliver right at the view edge) get clamped so the
  // agent never receives a negative or >1 value.
  func testClampsBelowZero() throws {
    let point = DropGeometry.normalize(
      point: CGPoint(x: -5, y: 1010),
      inViewBoundsSize: CGSize(width: 1280, height: 1000),
      isViewFlipped: false
    )
    XCTAssertEqual(point.x, 0)
    XCTAssertEqual(point.y, 0)
  }

  func testClampsAboveOne() throws {
    let point = DropGeometry.normalize(
      point: CGPoint(x: 1500, y: -100),
      inViewBoundsSize: CGSize(width: 1280, height: 1000),
      isViewFlipped: false
    )
    XCTAssertEqual(point.x, 1)
    XCTAssertEqual(point.y, 1)
  }

  // Zero-sized view shouldn't divide by zero; max(size, 1) protects us.
  func testZeroSizedViewDoesNotCrash() throws {
    let point = DropGeometry.normalize(
      point: CGPoint(x: 0, y: 0),
      inViewBoundsSize: .zero,
      isViewFlipped: false
    )
    XCTAssertEqual(point.x, 0)
    XCTAssertEqual(point.y, 1) // y flipped: (1 - 0/1) = 1, clamped
  }
}

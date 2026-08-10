import Foundation
import XCTest
@testable import tart

#if canImport(DiskImageKit)
  import DiskImageKit

  @available(macOS 27.0, *)
  final class DiskImageStackTests: XCTestCase {
    override func setUpWithError() throws {
      try super.setUpWithError()

      if #unavailable(macOS 27.0) {
        throw XCTSkip("DiskImageKit tests require macOS 27 or newer")
      }
    }

    func testCreatesAndAttachesRawBaseWithWritableOverlay() throws {
      let fixture = try Fixture(baseFormat: .raw)

      try fixture.disk.createWritableOverlay()
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.disk.writableOverlayURL.path))

      _ = try fixture.disk.makeAttachment()
    }

    func testCreatesAndAttachesASIFBaseWithPublishedOverlay() throws {
      let fixture = try Fixture(baseFormat: .asif, publishedOverlayCount: 1)

      try fixture.disk.createWritableOverlay()
      _ = try fixture.disk.makeAttachment()
    }

    func testCreatesAndAttachesMultiplePublishedOverlays() throws {
      let fixture = try Fixture(baseFormat: .asif, publishedOverlayCount: 2)

      try fixture.disk.createWritableOverlay()
      _ = try fixture.disk.makeAttachment()
    }

    func testCreatesAndAttachesLongPublishedOverlayChain() throws {
      let fixture = try Fixture(baseFormat: .asif, publishedOverlayCount: 8)

      try fixture.disk.createWritableOverlay()
      _ = try fixture.disk.makeAttachment()
    }

    func testAttachesStackReadOnly() throws {
      let fixture = try Fixture(baseFormat: .raw)
      try fixture.disk.createWritableOverlay()

      _ = try fixture.disk.makeAttachment(readOnly: true)
    }

    func testRejectsMissingWritableOverlayWhenAttaching() throws {
      let fixture = try Fixture(baseFormat: .raw)

      assertThrows(.writableOverlayMissing(fixture.disk.writableOverlayURL)) {
        try fixture.disk.makeAttachment()
      }
    }

    func testRejectsExistingWritableOverlayWhenCreating() throws {
      let fixture = try Fixture(baseFormat: .raw)
      XCTAssertTrue(FileManager.default.createFile(atPath: fixture.disk.writableOverlayURL.path, contents: nil))

      assertThrows(.writableOverlayAlreadyExists(fixture.disk.writableOverlayURL)) {
        try fixture.disk.createWritableOverlay()
      }
    }

    func testRejectsExistingCopyDestination() throws {
      let fixture = try Fixture(baseFormat: .raw)
      try fixture.disk.createWritableOverlay()

      let destinationURL = fixture.directory.appendingPathComponent("existing-overlay.asif")
      XCTAssertTrue(FileManager.default.createFile(atPath: destinationURL.path, contents: nil))

      assertThrows(.writableOverlayAlreadyExists(destinationURL)) {
        try fixture.disk.copyWritableOverlay(to: destinationURL)
      }
    }

    func testRejectsNonASIFPublishedOverlay() throws {
      let fixture = try Fixture(baseFormat: .raw)
      let overlayURL = fixture.directory.appendingPathComponent("published-raw.img")
      _ = try DiskImage(creating: .raw(url: overlayURL, blockCount: 8))
      fixture.disk = DiskImageStack(
        baseURL: fixture.disk.baseURL,
        baseFormat: fixture.disk.baseFormat,
        immutableOverlayURLs: [
          overlayURL,
        ],
        writableOverlayURL: fixture.disk.writableOverlayURL,
        blockSize: fixture.disk.blockSize,
        blockCount: fixture.disk.blockCount
      )

      assertThrows(.invalidDiskImage(overlayURL, "overlay must use ASIF format")) {
        try fixture.disk.createWritableOverlay()
      }
    }

    func testRejectsWrongBaseFormat() throws {
      let fixture = try Fixture(baseFormat: .raw)
      fixture.disk = DiskImageStack(
        baseURL: fixture.disk.baseURL,
        baseFormat: .asif,
        immutableOverlayURLs: fixture.disk.immutableOverlayURLs,
        writableOverlayURL: fixture.disk.writableOverlayURL,
        blockSize: fixture.disk.blockSize,
        blockCount: fixture.disk.blockCount
      )

      assertThrows(.invalidDiskImage(fixture.disk.baseURL, "base disk format does not match")) {
        try fixture.disk.createWritableOverlay()
      }
    }

    func testRejectsBlockSizeMismatch() throws {
      let fixture = try Fixture(baseFormat: .raw)
      fixture.disk = DiskImageStack(
        baseURL: fixture.disk.baseURL,
        baseFormat: fixture.disk.baseFormat,
        immutableOverlayURLs: fixture.disk.immutableOverlayURLs,
        writableOverlayURL: fixture.disk.writableOverlayURL,
        blockSize: 4096,
        blockCount: fixture.disk.blockCount
      )

      assertThrows(.invalidBlockLayout("immutable disk stack does not match manifest block size")) {
        try fixture.disk.createWritableOverlay()
      }
    }

    func testRejectsUnsupportedBlockSize() throws {
      let fixture = try Fixture(baseFormat: .raw)
      fixture.disk = DiskImageStack(
        baseURL: fixture.disk.baseURL,
        baseFormat: fixture.disk.baseFormat,
        immutableOverlayURLs: fixture.disk.immutableOverlayURLs,
        writableOverlayURL: fixture.disk.writableOverlayURL,
        blockSize: 123,
        blockCount: fixture.disk.blockCount
      )

      assertThrows(.invalidBlockLayout("unsupported stacked disk block size 123")) {
        try fixture.disk.createWritableOverlay()
      }
    }

    func testRejectsManifestBlockCountMismatch() throws {
      let fixture = try Fixture(baseFormat: .raw)
      fixture.disk = DiskImageStack(
        baseURL: fixture.disk.baseURL,
        baseFormat: fixture.disk.baseFormat,
        immutableOverlayURLs: fixture.disk.immutableOverlayURLs,
        writableOverlayURL: fixture.disk.writableOverlayURL,
        blockSize: fixture.disk.blockSize,
        blockCount: fixture.disk.blockCount + 1
      )

      assertThrows(.invalidBlockLayout("immutable disk stack does not match manifest block count")) {
        try fixture.disk.createWritableOverlay()
      }
    }

    func testCopiesAndGrowsWritableOverlay() throws {
      let fixture = try Fixture(baseFormat: .raw)
      try fixture.disk.createWritableOverlay()

      let copiedURL = fixture.directory.appendingPathComponent("copied-overlay.asif")
      try fixture.disk.copyWritableOverlay(to: copiedURL)
      fixture.disk = DiskImageStack(
        baseURL: fixture.disk.baseURL,
        baseFormat: fixture.disk.baseFormat,
        immutableOverlayURLs: fixture.disk.immutableOverlayURLs,
        writableOverlayURL: copiedURL,
        blockSize: fixture.disk.blockSize,
        blockCount: fixture.disk.blockCount
      )
      try fixture.disk.growWritableOverlay(toBlockCount: 16)

      let copied = try DiskImage(opening: .open(url: copiedURL, mode: .readOnly))
      XCTAssertEqual(copied.blockCount, 16)
    }

    func testRejectsOverlayFromDifferentASIFParent() throws {
      let fixture = try Fixture(baseFormat: .asif)
      let other = try Fixture(baseFormat: .asif, publishedOverlayCount: 1)
      fixture.disk = DiskImageStack(
        baseURL: fixture.disk.baseURL,
        baseFormat: fixture.disk.baseFormat,
        immutableOverlayURLs: other.disk.immutableOverlayURLs,
        writableOverlayURL: fixture.disk.writableOverlayURL,
        blockSize: fixture.disk.blockSize,
        blockCount: fixture.disk.blockCount
      )

      assertThrows(.invalidDiskImage(other.disk.immutableOverlayURLs[0], "ASIF overlay is incompatible with its parent")) {
        try fixture.disk.createWritableOverlay()
      }
    }

    func testRejectsWritableOverlayShrink() throws {
      let fixture = try Fixture(baseFormat: .raw)
      try fixture.disk.createWritableOverlay()

      assertThrows(.invalidDiskImage(fixture.disk.writableOverlayURL, "ASIF overlay block count shrinks the stacked disk")) {
        try fixture.disk.growWritableOverlay(toBlockCount: 4)
      }
    }

    private func assertThrows<T>(
      _ expected: DiskImageStackError,
      operation: () throws -> T
    ) {
      XCTAssertThrowsError(try operation()) { error in
        XCTAssertEqual(error as? DiskImageStackError, expected)
      }
    }

    private final class Fixture {
      let directory: URL
      var disk: DiskImageStack

      init(baseFormat: DiskImageFormat, publishedOverlayCount: Int = 0) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        let baseURL = directory.appendingPathComponent("base.img")
        switch baseFormat {
        case .raw:
          _ = try DiskImage(creating: .raw(url: baseURL, blockCount: 8))
        case .asif:
          _ = try DiskImage(creating: .asif(url: baseURL, blockCount: 8, blockSize: .bytes512))
        }

        var immutableOverlayURLs: [URL] = []
        var image = try DiskImage(opening: .open(url: baseURL, mode: .readOnly))
        for index in 0..<publishedOverlayCount {
          let overlayURL = directory.appendingPathComponent("published-\(index).asif")
          let stack = try image.appending(.asifLayer(url: overlayURL, type: .overlay))
          immutableOverlayURLs.append(overlayURL)
          image = stack
        }

        disk = DiskImageStack(
          baseURL: baseURL,
          baseFormat: baseFormat,
          immutableOverlayURLs: immutableOverlayURLs,
          writableOverlayURL: directory.appendingPathComponent("overlay.asif"),
          blockSize: 512,
          blockCount: 8
        )
      }

      deinit {
        try? FileManager.default.removeItem(at: directory)
      }
    }
  }
#endif

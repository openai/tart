import Foundation
import XCTest
@testable import tart

final class VMDirectoryLayoutTests: XCTestCase {
  func testStandaloneLayoutWithPinnedManifest() throws {
    let vmDir = try temporaryVMDirectory()

    try touch(vmDir.configURL)
    try touch(vmDir.nvramURL)
    try touch(vmDir.diskURL)
    try touch(vmDir.manifestURL)

    XCTAssertEqual(vmDir.layout, .standalone)
    XCTAssertTrue(vmDir.initialized)
    XCTAssertTrue(vmDir.isCachedImage)
    XCTAssertNoThrow(try vmDir.validateCachedImage(userFriendlyName: "standalone"))
  }

  func testStackedVMLayout() throws {
    let vmDir = try temporaryVMDirectory()

    try touch(vmDir.configURL)
    try touch(vmDir.nvramURL)
    try touch(vmDir.manifestURL)
    try touch(vmDir.overlayURL)

    XCTAssertEqual(vmDir.layout, .stackedLocal)
    XCTAssertTrue(vmDir.initialized)
    XCTAssertFalse(vmDir.isCachedImage)
  }

  func testStackedCachedImageLayout() throws {
    let vmDir = try temporaryVMDirectory()

    try touch(vmDir.configURL)
    try touch(vmDir.nvramURL)
    try touch(vmDir.manifestURL)

    XCTAssertEqual(vmDir.layout, .stackedOCIRecord)
    XCTAssertFalse(vmDir.initialized)
    XCTAssertTrue(vmDir.isCachedImage)
    XCTAssertNoThrow(try vmDir.validateCachedImage(userFriendlyName: "stacked"))
  }

  func testAmbiguousDiskAndOverlayIsNotInitialized() throws {
    let vmDir = try temporaryVMDirectory()

    try touch(vmDir.configURL)
    try touch(vmDir.nvramURL)
    try touch(vmDir.diskURL)
    try touch(vmDir.manifestURL)
    try touch(vmDir.overlayURL)

    XCTAssertNil(vmDir.layout)
    XCTAssertFalse(vmDir.initialized)
    XCTAssertFalse(vmDir.isCachedImage)
  }

  func testStackedVMAccountingUsesOverlay() throws {
    let vmDir = try temporaryVMDirectory()

    try Data("config".utf8).write(to: vmDir.configURL)
    try Data("nvram".utf8).write(to: vmDir.nvramURL)
    try Data("overlay".utf8).write(to: vmDir.overlayURL)
    try stackedManifest(blockSize: 512, blockCount: 8).toJSON().write(to: vmDir.manifestURL)

    XCTAssertEqual(
      try vmDir.sizeBytes(),
      try vmDir.configURL.sizeBytes() + vmDir.overlayURL.sizeBytes() + vmDir.nvramURL.sizeBytes()
    )
    XCTAssertEqual(
      try vmDir.allocatedSizeBytes(),
      try vmDir.configURL.allocatedSizeBytes() + vmDir.overlayURL.allocatedSizeBytes() + vmDir.nvramURL.allocatedSizeBytes()
    )
  }

  func testStackedCachedImageAccountingUsesManifestBlockLayout() throws {
    let vmDir = try temporaryVMDirectory()

    try Data("config".utf8).write(to: vmDir.configURL)
    try Data("nvram".utf8).write(to: vmDir.nvramURL)
    try stackedManifest(blockSize: 512, blockCount: 8).toJSON().write(to: vmDir.manifestURL)

    XCTAssertEqual(
      try vmDir.sizeBytes(),
      try vmDir.configURL.sizeBytes() + vmDir.nvramURL.sizeBytes()
    )
    XCTAssertEqual(
      try vmDir.allocatedSizeBytes(),
      try vmDir.configURL.allocatedSizeBytes() + vmDir.nvramURL.allocatedSizeBytes()
    )
    XCTAssertEqual(try vmDir.diskSizeBytes(), 4096)
  }

  func testStackedArchiveRequiresMacOS27() throws {
    if #available(macOS 27.0, *) {
      throw XCTSkip("macOS 26 compatibility test")
    }

    let vmDir = try temporaryVMDirectory()
    try Data("config".utf8).write(to: vmDir.configURL)
    try Data("nvram".utf8).write(to: vmDir.nvramURL)
    try Data("overlay".utf8).write(to: vmDir.overlayURL)
    try stackedManifest(blockSize: 512, blockCount: 8).toJSON().write(to: vmDir.manifestURL)
    let archiveURL = try temporaryVMDirectory().baseURL.appendingPathComponent("stacked.tvm")
    XCTAssertThrowsError(try vmDir.exportToArchive(path: archiveURL.path)) { error in
      guard case DiskImageStackError.unavailable = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
  }

  private func temporaryVMDirectory() throws -> VMDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }

    return VMDirectory(baseURL: url)
  }

  private func touch(_ url: URL) throws {
    XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
  }

  private func stackedManifest(blockSize: UInt64, blockCount: UInt64) -> OCIManifest {
    var disk = OCIManifestLayer(
      mediaType: diskV2MediaType,
      size: 1,
      digest: "sha256:transport",
      uncompressedSize: blockSize * blockCount,
      uncompressedContentDigest: "sha256:chunk"
    )
    disk.annotations?[diskFileContentDigestAnnotation] = "sha256:base"

    var manifest = OCIManifest(
      config: OCIManifestConfig(size: 1, digest: "sha256:oci-config"),
      layers: [
        OCIManifestLayer(mediaType: configMediaType, size: 1, digest: "sha256:config"),
        disk,
        OCIManifestLayer(mediaType: nvramMediaType, size: 1, digest: "sha256:nvram"),
      ]
    )
    manifest.annotations = [
      uncompressedDiskSizeAnnotation: String(blockSize * blockCount),
      diskBlockSizeAnnotation: String(blockSize),
    ]

    return manifest
  }
}

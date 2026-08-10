import Foundation
import XCTest
@testable import tart

#if canImport(DiskImageKit)
  import DiskImageKit

  @available(macOS 27.0, *)
  final class VMDirectoryDiskImageStackTests: XCTestCase {
    override func setUpWithError() throws {
      try super.setUpWithError()

      if #unavailable(macOS 27.0) {
        throw XCTSkip("DiskImageKit tests require macOS 27 or newer")
      }
    }

    func testBaseBlockLayoutReadsRawAndASIFImages() throws {
      let directory = try temporaryDirectory()
      let rawURL = directory.appendingPathComponent("base.raw")
      let asifURL = directory.appendingPathComponent("base.asif")
      _ = try DiskImage(creating: .raw(url: rawURL, blockCount: 8))
      _ = try DiskImage(creating: .asif(url: asifURL, blockCount: 16, blockSize: .bytes512))

      XCTAssertEqual(try DiskImageStack.baseBlockLayout(at: rawURL, expectedFormat: .raw).blockCount, 8)
      XCTAssertEqual(try DiskImageStack.baseBlockLayout(at: asifURL, expectedFormat: .asif).blockCount, 16)
    }

    func testCloneAsStackedBasePinsFlatManifestAndCreatesOverlay() throws {
      let contentStore = try temporaryContentStore()
      let source = try flatSource()
      let destination = try temporaryVMDirectory()

      try source.cloneAsStackedBase(to: destination, generateMAC: false, contentStore: contentStore)

      XCTAssertTrue(destination.isStackedVM)
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.diskURL.path))

      let contentDigest = try Digest.hash(source.diskURL)
      let manifest = try OCIManifest(fromJSON: Data(contentsOf: destination.manifestURL))
      guard case .flat(let base) = try manifest.tartDiskRepresentation() else {
        return XCTFail("expected a pinned base-only manifest")
      }
      XCTAssertEqual(base.contentDigest, contentDigest)
      XCTAssertEqual(manifest.diskBlockSize(), 512)
      XCTAssertEqual(manifest.diskBlockCount(), 8)

      let stack = try destination.diskImageStack(contentStore: contentStore)
      XCTAssertEqual(stack.baseURL, try contentStore.contentURL(for: contentDigest))
      XCTAssertTrue(FileManager.default.fileExists(atPath: destination.overlayURL.path))
    }

    func testCloneAsStackedBaseSupportsASIFDisk() throws {
      let contentStore = try temporaryContentStore()
      let source = try flatSource(diskFormat: .asif)
      let destination = try temporaryVMDirectory()

      try source.cloneAsStackedBase(to: destination, generateMAC: false, contentStore: contentStore)

      let stack = try destination.diskImageStack(contentStore: contentStore)
      XCTAssertEqual(stack.baseFormat, .asif)
      XCTAssertTrue(destination.isStackedVM)
      _ = try stack.makeAttachment()
    }

    func testStackedCloneCanCopyOrCreateWritableOverlay() throws {
      let contentStore = try temporaryContentStore()
      let source = try flatSource()
      let stacked = try temporaryVMDirectory()
      try source.cloneAsStackedBase(to: stacked, generateMAC: false, contentStore: contentStore)

      let copied = try temporaryVMDirectory()
      try stacked.cloneStacked(to: copied, copyWritableOverlay: true, generateMAC: false, contentStore: contentStore)
      XCTAssertEqual(try Digest.hash(copied.overlayURL), try Digest.hash(stacked.overlayURL))

      let fresh = try temporaryVMDirectory()
      try stacked.cloneStacked(to: fresh, copyWritableOverlay: false, generateMAC: false, contentStore: contentStore)
      XCTAssertTrue(fresh.isStackedVM)
      XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.overlayURL.path))
    }

    func testResizeDiskGrowsWritableOverlay() throws {
      let contentStore = try temporaryContentStore()
      let source = try flatSource()
      let stacked = try temporaryVMDirectory()
      try source.cloneAsStackedBase(to: stacked, generateMAC: false, contentStore: contentStore)

      try stacked.resizeDisk(1, contentStore: contentStore)

      let image = try DiskImage(opening: .open(url: stacked.overlayURL, mode: .readOnly))
      XCTAssertEqual(image.blockCount, 1_000_000_000 / 512)
      XCTAssertEqual(try stacked.diskSizeBytes(), 1_000_000_000)
    }

    func testResolvesPublishedOverlayFromManifestAndCache() throws {
      let contentStore = try temporaryContentStore()
      let source = try flatSource()
      let baseOnly = try temporaryVMDirectory()
      try source.cloneAsStackedBase(to: baseOnly, generateMAC: false, contentStore: contentStore)

      let contentDigest = try Digest.hash(baseOnly.overlayURL)
      let temporaryContentURL = try contentStore.temporaryContentURL(for: contentDigest)
      try FileManager.default.copyItem(at: baseOnly.overlayURL, to: temporaryContentURL)
      _ = try contentStore.install(temporaryContentURL, contentDigest: contentDigest)

      var manifest = try OCIManifest(fromJSON: Data(contentsOf: baseOnly.manifestURL))
      var overlay = OCIManifestLayer(
        mediaType: asifOverlayMediaType,
        size: 1,
        digest: "sha256:overlay-transport",
        uncompressedSize: 1,
        uncompressedContentDigest: "sha256:overlay-chunk"
      )
      overlay.annotations?[diskFileContentDigestAnnotation] = contentDigest
      overlay.annotations?[diskFileChunkCountAnnotation] = "1"
      manifest.layers.insert(overlay, at: manifest.layers.count - 1)

      let destination = try temporaryVMDirectory()
      try FileManager.default.copyItem(at: baseOnly.configURL, to: destination.configURL)
      try FileManager.default.copyItem(at: baseOnly.nvramURL, to: destination.nvramURL)
      try manifest.toJSON().write(to: destination.manifestURL)

      let stack = try destination.diskImageStack(contentStore: contentStore)
      XCTAssertEqual(stack.immutableOverlayURLs, [try contentStore.contentURL(for: contentDigest)])
      try stack.createWritableOverlay()
      _ = try stack.makeAttachment()
    }

    private func flatSource(diskFormat: DiskImageFormat = .raw) throws -> VMDirectory {
      let vmDir = try temporaryVMDirectory()
      let config = VMConfig(
        platform: Linux(),
        cpuCountMin: 2,
        memorySizeMin: 512 * 1024 * 1024,
        diskFormat: diskFormat
      )
      try config.save(toURL: vmDir.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.nvramURL.path, contents: Data()))
      switch diskFormat {
      case .raw:
        _ = try DiskImage(creating: .raw(url: vmDir.diskURL, blockCount: 8))
      case .asif:
        _ = try DiskImage(creating: .asif(url: vmDir.diskURL, blockCount: 8, blockSize: .bytes512))
      }

      let diskChunk = OCIManifestLayer(
        mediaType: diskV2MediaType,
        size: 1,
        digest: "sha256:transport",
        uncompressedSize: 4096,
        uncompressedContentDigest: "sha256:chunk"
      )
      let manifest = OCIManifest(
        config: OCIManifestConfig(size: 1, digest: "sha256:oci-config"),
        layers: [
          OCIManifestLayer(mediaType: configMediaType, size: 1, digest: "sha256:config"),
          diskChunk,
          OCIManifestLayer(mediaType: nvramMediaType, size: 1, digest: "sha256:nvram"),
        ]
      )
      try manifest.toJSON().write(to: vmDir.manifestURL)

      return vmDir
    }

    private func temporaryContentStore() throws -> ContentStore {
      let url = try temporaryDirectory()
      return try ContentStore(baseURL: url)
    }

    private func temporaryVMDirectory() throws -> VMDirectory {
      VMDirectory(baseURL: try temporaryDirectory())
    }

    private func temporaryDirectory() throws -> URL {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
      addTeardownBlock {
        try? FileManager.default.removeItem(at: url)
      }

      return url
    }
  }
#endif

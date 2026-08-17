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

    func testStackedRemoteAdditionalDiskRetainsTemporaryVM() throws {
      try withTemporaryTartHome {
        let source = try flatSource()
        let stacked = try temporaryVMDirectory()
        try source.cloneAsStackedBase(to: stacked, generateMAC: false)

        let storage = try VMStorageOCI()
        let name = try RemoteName("example.com/org/image:latest")
        let cachedImage = try storage.create(name)
        try FileManager.default.copyItem(at: stacked.configURL, to: cachedImage.configURL)
        try FileManager.default.copyItem(at: stacked.nvramURL, to: cachedImage.nvramURL)
        try FileManager.default.copyItem(at: stacked.manifestURL, to: cachedImage.manifestURL)

        do {
          let additionalDisk = try AdditionalDisk(parseFrom: name.description)
          let entries = try temporaryEntries()
          XCTAssertEqual(entries.count, 1)
          XCTAssertTrue(VMDirectory(baseURL: entries[0]).isStackedVM)

          try Config().gc()
          XCTAssertEqual(try temporaryEntries(), entries)

          withExtendedLifetime(additionalDisk) {}
        }

        try Config().gc()
        XCTAssertTrue(try temporaryEntries().isEmpty)
      }
    }

    func testResizeDiskGrowsWritableOverlayAndPreservesParentGeometry() throws {
      let contentStore = try temporaryContentStore()
      let source = try flatSource()
      let stacked = try temporaryVMDirectory()
      try source.cloneAsStackedBase(to: stacked, generateMAC: false, contentStore: contentStore)

      try stacked.resizeDisk(1, contentStore: contentStore)

      let image = try DiskImage(opening: .open(url: stacked.overlayURL, mode: .readOnly))
      XCTAssertEqual(image.blockCount, 1_000_000_000 / 512)
      XCTAssertEqual(try stacked.diskSizeBytes(), 1_000_000_000)

      let manifest = try OCIManifest(fromJSON: Data(contentsOf: stacked.manifestURL))
      XCTAssertEqual(manifest.diskBlockSize(), 512)
      XCTAssertEqual(manifest.diskBlockCount(), 8)

      _ = try stacked.diskImageStack(contentStore: contentStore).makeAttachment()
    }

    func testStackedArchiveRoundTripsImmutableContentAndOverlay() throws {
      try withTemporaryTartHome {
        let source = try flatSource()
        let stacked = try temporaryVMDirectory()
        try source.cloneAsStackedBase(to: stacked, generateMAC: false)

        let contentDigest = try Digest.hash(source.diskURL)
        let contentStore = try ContentStore()
        let archivedOverlayDigest = try Digest.hash(stacked.overlayURL)
        let archiveURL = try temporaryDirectory().appendingPathComponent("stacked.tvm")
        try stacked.exportToArchive(path: archiveURL.path)

        let cachedBaseURL = try XCTUnwrap(try contentStore.existingContentURL(for: contentDigest))
        // Import must repair a corrupt cache entry from the valid archive
        // instead of discarding the archive copy as an apparent cache hit.
        try Data("corrupt".utf8).write(to: cachedBaseURL)
        XCTAssertNil(try contentStore.existingContentURL(for: contentDigest))

        let imported = try temporaryVMDirectory()
        try imported.importFromArchive(path: archiveURL.path)

        XCTAssertTrue(imported.isStackedVM)
        XCTAssertEqual(try Digest.hash(imported.overlayURL), archivedOverlayDigest)
        XCTAssertNotNil(try contentStore.existingContentURL(for: contentDigest))
        _ = try imported.diskImageStack().makeAttachment()
      }
    }

    func testStackedArchiveRejectsCorruptImmutableContent() throws {
      try withTemporaryTartHome {
        let source = try flatSource()
        let stacked = try temporaryVMDirectory()
        try source.cloneAsStackedBase(to: stacked, generateMAC: false)

        let contentDigest = try Digest.hash(source.diskURL)
        let contentStore = try ContentStore()
        let cachedBaseURL = try XCTUnwrap(try contentStore.contentURLIfPresent(for: contentDigest))
        try Data("corrupt".utf8).write(to: cachedBaseURL)

        let archiveURL = try temporaryDirectory().appendingPathComponent("stacked.tvm")
        XCTAssertThrowsError(try stacked.exportToArchive(path: archiveURL.path)) { error in
          guard case RuntimeError.ExportFailed(let message) = error else {
            return XCTFail("unexpected error: \(error)")
          }
          XCTAssertEqual(message, "VM is missing cached disk content \(contentDigest)")
        }
      }
    }

    func testStackedOCIArchiveSurvivesConcurrentRecordDeletion() throws {
      try withTemporaryTartHome {
        let source = try flatSource()
        let stacked = try temporaryVMDirectory()
        try source.cloneAsStackedBase(to: stacked, generateMAC: false)

        let manifest = try OCIManifest(fromJSON: Data(contentsOf: stacked.manifestURL))
        let storage = try VMStorageOCI()
        let record = try storage.create(RemoteName(
          host: "example.com",
          namespace: "org/image",
          reference: Reference(digest: try manifest.digest())
        ))
        try FileManager.default.copyItem(at: stacked.configURL, to: record.configURL)
        try FileManager.default.copyItem(at: stacked.nvramURL, to: record.nvramURL)
        try FileManager.default.copyItem(at: stacked.manifestURL, to: record.manifestURL)
        XCTAssertTrue(record.isStackedCachedImage)

        let archiveURL = try temporaryDirectory().appendingPathComponent("stacked-race.tvm")
        let contentStore = try ContentStore()
        let lockHeld = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let exportStarted = DispatchSemaphore(value: 0)
        let exportFinished = DispatchSemaphore(value: 0)
        let deletionStarted = DispatchSemaphore(value: 0)
        let deletionFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
          try? contentStore.withPruneLock {
            lockHeld.signal()
            releaseLock.wait()
          }
        }
        XCTAssertEqual(lockHeld.wait(timeout: .now() + 1), .success)

        // Queue export first so it is the next prune-lock waiter, then queue
        // deletion behind it. Export must finish staging everything it needs
        // before deletion can remove the source cached image.
        DispatchQueue.global().async {
          exportStarted.signal()
          try? record.exportToArchive(path: archiveURL.path)
          exportFinished.signal()
        }
        XCTAssertEqual(exportStarted.wait(timeout: .now() + 1), .success)
        Thread.sleep(forTimeInterval: 0.1)

        DispatchQueue.global().async {
          deletionStarted.signal()
          try? record.delete()
          deletionFinished.signal()
        }
        XCTAssertEqual(deletionStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(exportFinished.wait(timeout: .now() + 0.1), .timedOut)
        XCTAssertEqual(deletionFinished.wait(timeout: .now() + 0.1), .timedOut)

        releaseLock.signal()
        XCTAssertEqual(exportFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(deletionFinished.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.baseURL.path))

        let imported = try temporaryVMDirectory()
        try imported.importFromArchive(path: archiveURL.path)
        XCTAssertTrue(imported.isStackedVM)
        _ = try imported.diskImageStack().makeAttachment()
      }
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

    private func temporaryEntries() throws -> [URL] {
      try FileManager.default.contentsOfDirectory(
        at: Config().tartTmpDir,
        includingPropertiesForKeys: nil
      )
    }

    private func withTemporaryTartHome(_ body: () throws -> Void) throws {
      let home = try temporaryDirectory()
      let previousHome = ProcessInfo.processInfo.environment["TART_HOME"]
      setenv("TART_HOME", home.path, 1)
      defer {
        if let previousHome {
          setenv("TART_HOME", previousHome, 1)
        } else {
          unsetenv("TART_HOME")
        }
      }

      try body()
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

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

    func testFlattenStackedFoldsOverlaysIntoStandaloneRawDisk() throws {
      let contentStore = try temporaryContentStore()
      let source = try flatSource(blockCount: 2048)
      try write(block("base start"), at: 0, to: source.diskURL)
      try write(block("base end"), at: 2047 * 512, to: source.diskURL)
      let stacked = try temporaryVMDirectory()
      try source.cloneAsStackedBase(to: stacked, generateMAC: false, contentStore: contentStore)
      let stack = try stacked.diskImageStack(contentStore: contentStore)
      try write(block("overlay start"), at: 0, through: stack)
      try write(block("overlay middle"), at: 10 * 512, through: stack)

      let flattened = try temporaryVMDirectory()
      try stacked.flattenStacked(to: flattened, contentStore: contentStore)

      XCTAssertTrue(flattened.isStandalone)
      XCTAssertEqual(try VMConfig(fromURL: flattened.configURL).diskFormat, .raw)
      var expected = Data(count: 2048 * 512)
      expected.replaceSubrange(0..<512, with: block("overlay start"))
      expected.replaceSubrange((10 * 512)..<(11 * 512), with: block("overlay middle"))
      expected.replaceSubrange((2047 * 512)..<(2048 * 512), with: block("base end"))
      XCTAssertEqual(try Data(contentsOf: flattened.diskURL), expected)
      XCTAssertEqual(try read(stack), expected)
    }

    func testFlattenStackedSupportsASIFBase() throws {
      let contentStore = try temporaryContentStore()
      let source = try flatSource(diskFormat: .asif, blockCount: 2048)
      try write(block("base"), at: 512, through: source.diskURL)
      let stacked = try temporaryVMDirectory()
      try source.cloneAsStackedBase(to: stacked, generateMAC: false, contentStore: contentStore)
      let stack = try stacked.diskImageStack(contentStore: contentStore)
      try write(block("overlay"), at: 1024, through: stack)

      let flattened = try temporaryVMDirectory()
      try stacked.flattenStacked(to: flattened, contentStore: contentStore)

      let image = try DiskImage(opening: .open(url: flattened.diskURL, mode: .readOnly))
      XCTAssertEqual(image.format, .asif)
      XCTAssertNil(image.parentUUID)
      XCTAssertEqual(image.blockCount, 2048)
      let flattenedContents = try read(flattened.diskURL)
      XCTAssertEqual(flattenedContents.subdata(in: 512..<1024), block("base"))
      XCTAssertEqual(flattenedContents.subdata(in: 1024..<1536), block("overlay"))
      XCTAssertEqual(flattenedContents, try read(stack))
    }

    func testFlattenStackedKeepsBaseBlocksBelowGrownOverlay() throws {
      let contentStore = try temporaryContentStore()
      let source = try flatSource(blockCount: 2048)
      try write(block("base end"), at: 2047 * 512, to: source.diskURL)
      let stacked = try temporaryVMDirectory()
      try source.cloneAsStackedBase(to: stacked, generateMAC: false, contentStore: contentStore)
      try stacked.resizeDisk(1, contentStore: contentStore)

      let flattened = try temporaryVMDirectory()
      try stacked.flattenStacked(to: flattened, contentStore: contentStore)

      XCTAssertEqual(try flattened.diskURL.sizeBytes(), 1_000_000_000)
      let disk = try FileHandle(forReadingFrom: flattened.diskURL)
      defer { try? disk.close() }
      try disk.seek(toOffset: 2047 * 512)
      XCTAssertEqual(try disk.read(upToCount: 1024), block("base end") + Data(count: 512))
    }

    func testFlattenStackedRejectsOverlayOfAnotherBase() throws {
      let contentStore = try temporaryContentStore()
      // Only ASIF bases have a UUID that their overlays can be checked against
      let stacked = try temporaryVMDirectory()
      try flatSource(diskFormat: .asif, blockCount: 2048)
        .cloneAsStackedBase(to: stacked, generateMAC: false, contentStore: contentStore)
      let other = try temporaryVMDirectory()
      try flatSource(diskFormat: .asif, blockCount: 2048)
        .cloneAsStackedBase(to: other, generateMAC: false, contentStore: contentStore)
      try FileManager.default.removeItem(at: stacked.overlayURL)
      try FileManager.default.copyItem(at: other.overlayURL, to: stacked.overlayURL)

      let flattened = try temporaryVMDirectory()
      XCTAssertThrowsError(try stacked.flattenStacked(to: flattened, contentStore: contentStore))
      XCTAssertFalse(FileManager.default.fileExists(atPath: flattened.diskURL.path))
    }

    func testFlattenStackedRejectsSuspendedVM() throws {
      let contentStore = try temporaryContentStore()
      let stacked = try temporaryVMDirectory()
      try flatSource(blockCount: 2048).cloneAsStackedBase(to: stacked, generateMAC: false, contentStore: contentStore)
      XCTAssertTrue(FileManager.default.createFile(atPath: stacked.stateURL.path, contents: Data()))

      let flattened = try temporaryVMDirectory()
      XCTAssertThrowsError(try stacked.flattenStacked(to: flattened, contentStore: contentStore))
      XCTAssertFalse(FileManager.default.fileExists(atPath: flattened.diskURL.path))
    }

    func testFlattenCommandReplacesStackedVMWithStandaloneVM() async throws {
      try await withTemporaryTartHome {
        let source = try flatSource(blockCount: 2048)
        try write(block("base"), at: 0, to: source.diskURL)
        let localStorage = try VMStorageLocal()
        let stacked = try localStorage.create("vm")
        try source.cloneAsStackedBase(to: stacked, generateMAC: false)

        try await Flatten.parse(["vm"]).run()

        let flattened = try localStorage.open("vm")
        XCTAssertTrue(flattened.isStandalone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flattened.manifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flattened.overlayURL.path))
        XCTAssertEqual(try Data(contentsOf: flattened.diskURL), try Data(contentsOf: source.diskURL))
      }
    }

    func testFlattenAppliesOverlaysFromBottomToTop() throws {
      let directory = try temporaryDirectory()
      let baseURL = directory.appendingPathComponent("base.asif")
      let lowerURL = directory.appendingPathComponent("lower.asif")
      let upperURL = directory.appendingPathComponent("upper.asif")

      _ = try DiskImage(creating: .asif(url: baseURL, blockCount: 2048, blockSize: .bytes512))
      _ = try DiskImage(opening: .open(url: baseURL, mode: .readOnly))
        .appending(.asifLayer(url: lowerURL, type: .overlay))
      try write(block("lower"), at: 0, through: baseURL, overlays: [lowerURL])
      try write(block("lower"), at: 512, through: baseURL, overlays: [lowerURL])

      _ = try DiskImage(opening: .open(url: baseURL, mode: .readOnly))
        .appending(DiskImage(opening: .open(url: lowerURL, mode: .readOnly)))
        .appending(.asifLayer(url: upperURL, type: .overlay))
      try write(block("upper"), at: 0, through: baseURL, overlays: [lowerURL, upperURL])

      let stack = DiskImageStack(
        baseURL: baseURL,
        baseFormat: .asif,
        immutableOverlayURLs: [lowerURL],
        writableOverlayURL: upperURL,
        blockSize: 512,
        blockCount: 2048
      )
      let flattenedURL = directory.appendingPathComponent("flattened.asif")
      try stack.flatten(to: flattenedURL)

      let flattenedContents = try read(flattenedURL)
      XCTAssertEqual(flattenedContents.subdata(in: 0..<512), block("upper"))
      XCTAssertEqual(flattenedContents.subdata(in: 512..<1024), block("lower"))
      XCTAssertEqual(flattenedContents, try read(stack))
    }

    private func block(_ text: String) -> Data {
      var data = Data(text.utf8)
      data.append(Data(count: 512 - data.count))

      return data
    }

    private func write(_ data: Data, at offset: UInt64, to url: URL) throws {
      let file = try FileHandle(forWritingTo: url)
      defer { try? file.close() }
      try file.seek(toOffset: offset)
      try file.write(contentsOf: data)
    }

    /// Writes to an attached disk image, so that writes to a stack land in its writable overlay
    private func write(_ data: Data, at offset: UInt64, through url: URL, overlays: [URL] = []) throws {
      let device = try attach(url, overlays: overlays, readOnly: false)
      defer { detach(device) }

      try write(data, at: offset, to: URL(fileURLWithPath: "/dev/r\(device)"))
    }

    private func write(_ data: Data, at offset: UInt64, through stack: DiskImageStack) throws {
      try write(data, at: offset, through: stack.baseURL, overlays: stack.immutableOverlayURLs + [stack.writableOverlayURL])
    }

    /// Reads the blocks of a disk image the way a guest sees them
    private func read(_ url: URL, overlays: [URL] = []) throws -> Data {
      let device = try attach(url, overlays: overlays, readOnly: true)
      defer { detach(device) }

      let disk = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/r\(device)"))
      defer { try? disk.close() }

      return try disk.readToEnd() ?? Data()
    }

    private func read(_ stack: DiskImageStack) throws -> Data {
      try read(stack.baseURL, overlays: stack.immutableOverlayURLs + [stack.writableOverlayURL])
    }

    private func attach(_ url: URL, overlays: [URL], readOnly: Bool) throws -> String {
      var arguments = ["image", "attach", "--noMount"]
      if readOnly {
        arguments.append("--readOnly")
      }
      for overlayURL in overlays {
        arguments += ["--shadow", overlayURL.path]
      }
      arguments.append(url.path)

      let output = try diskutil(arguments)
      guard let device = output.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("/dev/disk") }) else {
        throw RuntimeError.Generic("diskutil image attach didn't report a device: \(output)")
      }

      return String(device.dropFirst("/dev/".count))
    }

    private func detach(_ device: String) {
      do {
        _ = try diskutil(["eject", device])
      } catch {
        XCTFail("failed to detach \(device): \(error)")
      }
    }

    private func diskutil(_ arguments: [String]) throws -> String {
      let stdout = Pipe()
      let stderr = Pipe()
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
      process.arguments = arguments
      process.standardOutput = stdout
      process.standardError = stderr
      try process.run()
      let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      process.waitUntilExit()

      guard process.terminationStatus == 0 else {
        throw RuntimeError.Generic("diskutil \(arguments.joined(separator: " ")) failed: \(errorOutput)\(output)")
      }

      return output
    }

    private func flatSource(diskFormat: DiskImageFormat = .raw, blockCount: Int = 8) throws -> VMDirectory {
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
        _ = try DiskImage(creating: .raw(url: vmDir.diskURL, blockCount: blockCount))
      case .asif:
        _ = try DiskImage(creating: .asif(url: vmDir.diskURL, blockCount: blockCount, blockSize: .bytes512))
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

    private func withTemporaryTartHome(_ body: () async throws -> Void) async throws {
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

      try await body()
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

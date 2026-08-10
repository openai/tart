import Foundation
import XCTest
@testable import tart

#if canImport(DiskImageKit)
  import DiskImageKit
#endif

final class VMStorageOCITests: XCTestCase {
  func testPopulateStandalonePushedImageCachesDiskAndManifest() throws {
    try withTemporaryTartHome {
      let source = try standaloneSource(diskData: Data("disk".utf8))
      let manifest = try flatManifest()
      let name = try digestName(for: manifest)
      let storage = try VMStorageOCI()

      try storage.populate(name, from: source, manifest: manifest)

      let cached = try storage.open(name)
      XCTAssertTrue(cached.isStandalone)
      XCTAssertEqual(try Data(contentsOf: cached.diskURL), Data("disk".utf8))
      XCTAssertEqual(try OCIManifest(fromJSON: Data(contentsOf: cached.manifestURL)), manifest)
    }
  }

  func testBaseCloneRequiresManifestForLegacyStandaloneCachedImage() throws {
    try withTemporaryTartHome {
      let manifest = try flatManifest()
      let name = try digestName(for: manifest)
      let storage = try VMStorageOCI()
      let record = try storage.create(name)
      try config().save(toURL: record.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: record.nvramURL.path, contents: Data()))
      XCTAssertTrue(FileManager.default.createFile(atPath: record.diskURL.path, contents: Data()))

      XCTAssertTrue(try storage.hasUsableCachedImageForClone(name))
      XCTAssertFalse(try storage.hasUsableCachedImageForClone(name, requireManifest: true))
    }
  }

  func testCloneCacheCheckRejectsMissingOrWrongSizedStackedContent() throws {
    try withTemporaryTartHome {
      let baseData = Data("base".utf8)
      let overlayData = Data("overlay".utf8)
      let baseDigest = Digest.hash(baseData)
      let overlayDigest = Digest.hash(overlayData)
      let manifest = try stackedManifest(
        baseContentDigest: baseDigest,
        overlayContentDigest: overlayDigest,
        baseUncompressedSize: UInt64(baseData.count),
        overlayUncompressedSize: UInt64(overlayData.count)
      )
      let name = try digestName(for: manifest)
      let storage = try VMStorageOCI()
      let record = try storage.create(name)
      try config().save(toURL: record.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: record.nvramURL.path, contents: Data()))
      try manifest.toJSON().write(to: record.manifestURL)

      XCTAssertFalse(try storage.hasUsableCachedImageForClone(name))

      let contentStore = try ContentStore()
      try installContent(baseData, contentDigest: baseDigest, into: contentStore)
      try installContent(overlayData, contentDigest: overlayDigest, into: contentStore)
      XCTAssertTrue(try storage.hasUsableCachedImageForClone(name))

      try Data("bad".utf8).write(to: try contentStore.contentURL(for: overlayDigest))
      XCTAssertFalse(try storage.hasUsableCachedImageForClone(name))
    }
  }

  func testListIncludesStackedCachedImage() throws {
    try withTemporaryTartHome {
      let manifest = try stackedManifest()
      let name = try digestName(for: manifest)
      let storage = try VMStorageOCI()
      let record = try storage.create(name)
      try config().save(toURL: record.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: record.nvramURL.path, contents: Data()))
      try manifest.toJSON().write(to: record.manifestURL)

      XCTAssertTrue(try storage.list().contains { $0.0 == name.description })
      XCTAssertEqual(try record.diskSizeBytes(), 4096)
      XCTAssertNoThrow(try record.allocatedSizeBytes())
    }
  }

  func testStackedCacheHitRequiresVerifiedContentAndSizesMissingFiles() throws {
    try withTemporaryTartHome {
      let baseData = Data("base".utf8)
      let overlayData = Data("overlay".utf8)
      let baseDigest = Digest.hash(baseData)
      let overlayDigest = Digest.hash(overlayData)
      let manifest = try stackedManifest(
        baseContentDigest: baseDigest,
        overlayContentDigest: overlayDigest,
        baseUncompressedSize: 10,
        overlayUncompressedSize: 20
      )
      let name = try digestName(for: manifest)
      let storage = try VMStorageOCI()
      let record = try storage.create(name)
      try config().save(toURL: record.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: record.nvramURL.path, contents: Data()))
      try manifest.toJSON().write(to: record.manifestURL)

      XCTAssertFalse(try storage.hasCompleteCachedImage(name, manifest: manifest))
      XCTAssertEqual(try storage.requiredDiskStorageBytes(for: manifest), 30)

      let contentStore = try ContentStore()
      try installContent(baseData, contentDigest: baseDigest, into: contentStore)
      XCTAssertFalse(try storage.hasCompleteCachedImage(name, manifest: manifest))
      XCTAssertEqual(try storage.requiredDiskStorageBytes(for: manifest), 20)

      try installContent(overlayData, contentDigest: overlayDigest, into: contentStore)
      XCTAssertTrue(try storage.hasCompleteCachedImage(name, manifest: manifest))
      XCTAssertEqual(try storage.requiredDiskStorageBytes(for: manifest), 0)

      let overlayURL = try contentStore.contentURL(for: overlayDigest)
      try Data("corrupt".utf8).write(to: overlayURL)
      XCTAssertFalse(try storage.hasCompleteCachedImage(name, manifest: manifest))
      XCTAssertEqual(try storage.requiredDiskStorageBytes(for: manifest), 20)
    }
  }

  func testStandaloneLayerCacheIgnoresStackedCachedImages() async throws {
    try await withTemporaryTartHome {
      var targetManifest = try flatManifest()
      var stackedCandidateManifest = try stackedManifest()
      let sharedDiskSize = 2 * 1024 * 1024 * 1024
      targetManifest.layers[1].size = sharedDiskSize
      stackedCandidateManifest.layers[1] = targetManifest.layers[1]

      let candidateName = try digestName(for: stackedCandidateManifest)
      let storage = try VMStorageOCI()
      let candidate = try storage.create(candidateName)
      try config().save(toURL: candidate.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: candidate.nvramURL.path, contents: Data()))
      try stackedCandidateManifest.toJSON().write(to: candidate.manifestURL)

      let targetName = RemoteName(
        host: "example.com",
        namespace: "org/target",
        reference: Reference(digest: try targetManifest.digest())
      )
      let registry = try Registry(host: targetName.host, namespace: targetName.namespace)

      let layerCache = try await storage.chooseLocalLayerCache(targetName, targetManifest, registry)
      XCTAssertNil(layerCache)
    }
  }

  #if canImport(DiskImageKit)
    @available(macOS 27.0, *)
    func testPopulateStackedPushedImageCachesImmutableTopOverlay() throws {
      if #unavailable(macOS 27.0) {
        throw XCTSkip("DiskImageKit tests require macOS 27 or newer")
      }

      try withTemporaryTartHome {
        let source = try diskImageSource()
        let stacked = try temporaryVMDirectory()
        try source.cloneAsStackedBase(to: stacked, generateMAC: false)

        var manifest = try OCIManifest(fromJSON: Data(contentsOf: stacked.manifestURL))
        let contentDigest = try Digest.hash(stacked.overlayURL)
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

        let name = try digestName(for: manifest)
        let storage = try VMStorageOCI()
        try storage.populate(name, from: stacked, manifest: manifest)

        let cached = try storage.open(name)
        XCTAssertTrue(cached.isStackedCachedImage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.overlayURL.path))
        XCTAssertEqual(try OCIManifest(fromJSON: Data(contentsOf: cached.manifestURL)), manifest)

        let cachedContent = try XCTUnwrap(try ContentStore().existingContentURL(for: contentDigest))
        XCTAssertEqual(try Digest.hash(cachedContent), contentDigest)
      }
    }
  #endif

  private func standaloneSource(diskData: Data) throws -> VMDirectory {
    let vmDir = try temporaryVMDirectory()
    try config().save(toURL: vmDir.configURL)
    XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.nvramURL.path, contents: Data()))
    try diskData.write(to: vmDir.diskURL)

    return vmDir
  }

  #if canImport(DiskImageKit)
    @available(macOS 27.0, *)
    private func diskImageSource() throws -> VMDirectory {
      let vmDir = try temporaryVMDirectory()
      try config().save(toURL: vmDir.configURL)
      XCTAssertTrue(FileManager.default.createFile(atPath: vmDir.nvramURL.path, contents: Data()))
      _ = try DiskImage(creating: .raw(url: vmDir.diskURL, blockCount: 8))
      try flatManifest().toJSON().write(to: vmDir.manifestURL)

      return vmDir
    }
  #endif

  private func config() -> VMConfig {
    VMConfig(
      platform: Linux(),
      cpuCountMin: 2,
      memorySizeMin: 512 * 1024 * 1024,
      diskFormat: .raw
    )
  }

  private func flatManifest() throws -> OCIManifest {
    let disk = OCIManifestLayer(
      mediaType: diskV2MediaType,
      size: 1,
      digest: "sha256:disk-transport",
      uncompressedSize: 1,
      uncompressedContentDigest: "sha256:disk-chunk"
    )

    return OCIManifest(
      config: OCIManifestConfig(size: 1, digest: "sha256:oci-config"),
      layers: [
        OCIManifestLayer(mediaType: configMediaType, size: 1, digest: "sha256:config"),
        disk,
        OCIManifestLayer(mediaType: nvramMediaType, size: 1, digest: "sha256:nvram"),
      ]
    )
  }

  private func stackedManifest(
    baseContentDigest: String = "sha256:base",
    overlayContentDigest: String = "sha256:overlay",
    baseUncompressedSize: UInt64 = 1,
    overlayUncompressedSize: UInt64 = 1
  ) throws -> OCIManifest {
    var manifest = try flatManifest()
    manifest.annotations?[diskBlockSizeAnnotation] = "512"
    manifest.annotations?[uncompressedDiskSizeAnnotation] = "4096"
    manifest.layers[1].annotations?[diskFileContentDigestAnnotation] = baseContentDigest
    manifest.layers[1].annotations?[uncompressedSizeAnnotation] = String(baseUncompressedSize)
    var overlay = OCIManifestLayer(
      mediaType: asifOverlayMediaType,
      size: 1,
      digest: "sha256:overlay-transport",
      uncompressedSize: overlayUncompressedSize,
      uncompressedContentDigest: "sha256:overlay-chunk"
    )
    overlay.annotations?[diskFileContentDigestAnnotation] = overlayContentDigest
    overlay.annotations?[diskFileChunkCountAnnotation] = "1"
    manifest.layers.insert(overlay, at: manifest.layers.count - 1)

    return manifest
  }

  private func installContent(_ data: Data, contentDigest: String, into contentStore: ContentStore) throws {
    let temporaryURL = try contentStore.temporaryContentURL(for: contentDigest)
    try data.write(to: temporaryURL)
    _ = try contentStore.install(temporaryURL, contentDigest: contentDigest)
  }

  private func digestName(for manifest: OCIManifest) throws -> RemoteName {
    RemoteName(
      host: "example.com",
      namespace: "org/image",
      reference: Reference(digest: try manifest.digest())
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

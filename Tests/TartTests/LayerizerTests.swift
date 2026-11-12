import XCTest
@testable import tart

final class LayerizerTests: XCTestCase {
  var registryRunner: RegistryRunner?

  var registry: Registry {
    registryRunner!.registry
  }

  override func setUp() async throws {
    try await super.setUp()

    do {
      registryRunner = try await RegistryRunner()
    } catch {
      throw XCTSkip("Registry is unavailable: \(error)")
    }
  }

  override func tearDown() async throws {
    try await super.tearDown()

    registryRunner = nil
  }

  func testDiskV2() async throws {
    // Original disk file to be pushed to the registry
    let originalDiskFileURL = try fileWithRandomData(sizeBytes: 1 * 1024 * 1024 * 1024)
    addTeardownBlock {
      try FileManager.default.removeItem(at: originalDiskFileURL)
    }

    // Disk file to be pulled from the registry
    // and compared against the original disk file
    let pulledDiskFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    print("pushing disk...")
    let diskLayers = try await DiskV2.push(
      diskURL: originalDiskFileURL,
      mediaType: diskV2MediaType,
      registry: registry,
      chunkSizeMb: 0,
      concurrency: 4,
      progress: Progress()
    )

    print("pulling disk...")
    try await DiskV2.pull(registry: registry, diskLayers: diskLayers, diskURL: pulledDiskFileURL, concurrency: 16, progress: Progress())

    print("comparing disks...")
    try XCTAssertEqual(Digest.hash(originalDiskFileURL), Digest.hash(pulledDiskFileURL))
  }

  func testDiskV2ReusesRememberedChunkWithoutCompressing() async throws {
    let diskURL = try fileWithRandomData(sizeBytes: 513 * 1024 * 1024)
    addTeardownBlock {
      try FileManager.default.removeItem(at: diskURL)
    }

    // Remember an unrelated blob for the first chunk,
    // so that we can tell whether the chunk was compressed or not
    let sentinelBlob = Data("sentinel".utf8)
    let sentinelDigest = try await registry.pushBlob(fromData: sentinelBlob)
    let firstChunkSize: UInt64 = 512 * 1024 * 1024
    let firstChunkDigest = try Digest.hash(diskURL, offset: 0, size: firstChunkSize)
    let chunkCache = try temporaryChunkCache()
    try chunkCache.remember(Descriptor(size: sentinelBlob.count, digest: sentinelDigest), for: firstChunkDigest)

    let diskLayers = try await DiskV2.push(
      diskURL: diskURL,
      mediaType: diskV2MediaType,
      registry: registry,
      chunkSizeMb: 0,
      concurrency: 4,
      progress: Progress(),
      chunkCache: chunkCache
    )

    XCTAssertEqual(diskLayers.count, 2)
    XCTAssertEqual(diskLayers[0].digest, sentinelDigest)
    XCTAssertEqual(diskLayers[0].size, sentinelBlob.count)
    XCTAssertEqual(diskLayers[0].uncompressedSize(), firstChunkSize)
    XCTAssertEqual(diskLayers[0].uncompressedContentDigest(), firstChunkDigest)
    XCTAssertNotEqual(diskLayers[1].digest, sentinelDigest)
    let secondChunkExists = try await registry.blobExists(diskLayers[1].digest)
    XCTAssertTrue(secondChunkExists)
  }

  func testDiskV2CompressesRememberedChunkMissingFromRegistry() async throws {
    let diskURL = try fileWithRandomData(sizeBytes: 64 * 1024 * 1024)
    addTeardownBlock {
      try FileManager.default.removeItem(at: diskURL)
    }

    let diskDigest = try Digest.hash(diskURL)
    let missingDigest = Digest.hash(Data("never pushed".utf8))
    let chunkCache = try temporaryChunkCache()
    try chunkCache.remember(Descriptor(size: 12, digest: missingDigest), for: diskDigest)

    let diskLayers = try await DiskV2.push(
      diskURL: diskURL,
      mediaType: diskV2MediaType,
      registry: registry,
      chunkSizeMb: 0,
      concurrency: 4,
      progress: Progress(),
      chunkCache: chunkCache
    )

    XCTAssertEqual(diskLayers.count, 1)
    XCTAssertNotEqual(diskLayers[0].digest, missingDigest)
    XCTAssertEqual(chunkCache.compressedBlob(for: diskDigest)?.digest, diskLayers[0].digest)

    let pulledDiskURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock {
      try FileManager.default.removeItem(at: pulledDiskURL)
    }
    try await DiskV2.pull(registry: registry, diskLayers: diskLayers, diskURL: pulledDiskURL, concurrency: 4, progress: Progress())
    try XCTAssertEqual(Digest.hash(pulledDiskURL), diskDigest)
  }

  func testDiskV2RepushReusesUnchangedChunks() async throws {
    let diskURL = try fileWithRandomData(sizeBytes: 576 * 1024 * 1024)
    addTeardownBlock {
      try FileManager.default.removeItem(at: diskURL)
    }

    let chunkCache = try temporaryChunkCache()
    let originalLayers = try await DiskV2.push(
      diskURL: diskURL,
      mediaType: diskV2MediaType,
      registry: registry,
      chunkSizeMb: 0,
      concurrency: 4,
      progress: Progress(),
      chunkCache: chunkCache
    )
    for layer in originalLayers {
      XCTAssertEqual(chunkCache.compressedBlob(for: layer.uncompressedContentDigest()!)?.digest, layer.digest)
    }

    // Change the second chunk only
    let disk = try FileHandle(forWritingTo: diskURL)
    try disk.seek(toOffset: 512 * 1024 * 1024 + 4096)
    try disk.write(contentsOf: Data("changed".utf8))
    try disk.close()

    let repushedLayers = try await DiskV2.push(
      diskURL: diskURL,
      mediaType: diskV2MediaType,
      registry: registry,
      chunkSizeMb: 0,
      concurrency: 4,
      progress: Progress(),
      chunkCache: chunkCache
    )

    XCTAssertEqual(repushedLayers[0].digest, originalLayers[0].digest)
    XCTAssertNotEqual(repushedLayers[1].digest, originalLayers[1].digest)

    let pulledDiskURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock {
      try FileManager.default.removeItem(at: pulledDiskURL)
    }
    try await DiskV2.pull(registry: registry, diskLayers: repushedLayers, diskURL: pulledDiskURL, concurrency: 4, progress: Progress())
    try XCTAssertEqual(Digest.hash(pulledDiskURL), Digest.hash(diskURL))
  }

  private func temporaryChunkCache() throws -> CompressedChunkCache {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }

    return try CompressedChunkCache(baseURL: url)
  }

  private func fileWithRandomData(sizeBytes: Int) throws -> URL {
    let devUrandom = try FileHandle(forReadingFrom: URL(filePath: "/dev/urandom"))

    let temporaryFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: temporaryFileURL.path, contents: nil)
    let temporaryFile = try FileHandle(forWritingTo: temporaryFileURL)

    var remainingBytes = sizeBytes

    while remainingBytes > 0 {
      let randomData = try devUrandom.read(upToCount: min(64 * 1024 * 1024, remainingBytes))!
      remainingBytes -= randomData.count
      try temporaryFile.write(contentsOf: randomData)
    }

    try devUrandom.close()

    try temporaryFile.close()

    return temporaryFileURL
  }
}

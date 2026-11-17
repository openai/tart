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

  func testDiskV2ResumedPullOverwritesOtherData() async throws {
    // Two layers of random and all-zero chunks, ending in a short zero chunk
    let originalDiskFileURL = try fileWithMixedData(sizeBytes: 604 * 1024 * 1024 + 12345)
    addTeardownBlock {
      try FileManager.default.removeItem(at: originalDiskFileURL)
    }

    // A bigger disk left behind by an interrupted pull of another image
    let pulledDiskFileURL = try fileWithRandomData(sizeBytes: 640 * 1024 * 1024)
    addTeardownBlock {
      try FileManager.default.removeItem(at: pulledDiskFileURL)
    }

    let diskLayers = try await DiskV2.push(diskURL: originalDiskFileURL, mediaType: diskV2MediaType, registry: registry,
                                           chunkSizeMb: 0, concurrency: 4, progress: Progress())
    XCTAssertEqual(diskLayers.count, 2)

    try await DiskV2.pull(registry: registry, diskLayers: diskLayers, diskURL: pulledDiskFileURL, concurrency: 4, progress: Progress())

    try XCTAssertEqual(Digest.hash(originalDiskFileURL), Digest.hash(pulledDiskFileURL))
  }

  func testDiskV2ResumedDeduplicatedPullOverwritesOtherData() async throws {
    let originalDiskFileURL = try fileWithMixedData(sizeBytes: 20 * 1024 * 1024 + 12345)
    addTeardownBlock {
      try FileManager.default.removeItem(at: originalDiskFileURL)
    }

    // A disk left behind by an interrupted pull that cloned another base
    let pulledDiskFileURL = try fileWithRandomData(sizeBytes: 20 * 1024 * 1024 + 12345)
    addTeardownBlock {
      try FileManager.default.removeItem(at: pulledDiskFileURL)
    }

    let diskLayers = try await DiskV2.push(diskURL: originalDiskFileURL, mediaType: diskV2MediaType, registry: registry,
                                           chunkSizeMb: 0, concurrency: 1, progress: Progress())

    // The local layer cache has the same layers
    let manifest = OCIManifest(config: OCIManifestConfig(size: 1, digest: "sha256:oci-config"), layers: diskLayers)
    let localLayerCache = try XCTUnwrap(LocalLayerCache("cache", 0, originalDiskFileURL, manifest))

    try await DiskV2.pull(registry: registry, diskLayers: diskLayers, diskURL: pulledDiskFileURL, concurrency: 1,
                          progress: Progress(), localLayerCache: localLayerCache, deduplicate: true)

    try XCTAssertEqual(Digest.hash(originalDiskFileURL), Digest.hash(pulledDiskFileURL))
  }

  // Alternates 4 MiB chunks of random data and zeros
  private func fileWithMixedData(sizeBytes: Int) throws -> URL {
    let devUrandom = try FileHandle(forReadingFrom: URL(filePath: "/dev/urandom"))

    let temporaryFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: temporaryFileURL.path, contents: nil)
    let temporaryFile = try FileHandle(forWritingTo: temporaryFileURL)

    let chunkSizeBytes = 4 * 1024 * 1024
    var remainingBytes = sizeBytes
    var random = true

    while remainingBytes > 0 {
      let count = min(chunkSizeBytes, remainingBytes)
      let data = random ? try devUrandom.read(upToCount: count)! : Data(count: count)
      try temporaryFile.write(contentsOf: data)
      remainingBytes -= data.count
      random.toggle()
    }

    try devUrandom.close()

    try temporaryFile.close()

    return temporaryFileURL
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

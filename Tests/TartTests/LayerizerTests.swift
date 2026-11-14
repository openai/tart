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

  func testDiskV2PullFailsWhenALayerFails() async throws {
    let originalDiskFileURL = try fileWithRandomData(sizeBytes: 16 * 1024 * 1024)
    let pulledDiskFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock {
      try FileManager.default.removeItem(at: originalDiskFileURL)
      try? FileManager.default.removeItem(at: pulledDiskFileURL)
    }

    var diskLayers = try await DiskV2.push(diskURL: originalDiskFileURL, mediaType: diskV2MediaType, registry: registry,
                                           chunkSizeMb: 0, concurrency: 1, progress: Progress())

    // The last layer's blob doesn't exist in the registry
    let missingLayer = diskLayers[0]
    diskLayers.append(OCIManifestLayer(mediaType: missingLayer.mediaType, size: missingLayer.size,
                                       digest: "sha256:" + String(repeating: "0", count: 64),
                                       uncompressedSize: missingLayer.uncompressedSize(),
                                       uncompressedContentDigest: missingLayer.uncompressedContentDigest()))

    do {
      try await DiskV2.pull(registry: registry, diskLayers: diskLayers, diskURL: pulledDiskFileURL, concurrency: 1, progress: Progress())
      XCTFail("pull should fail when a layer can't be fetched")
    } catch RegistryError.UnexpectedHTTPStatusCode(_, let code, _) {
      XCTAssertEqual(code, 404)
    }
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

import XCTest
@testable import tart

final class RegistryTests: XCTestCase {
  var registryRunner: RegistryRunner?

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

  var registry: Registry {
    registryRunner!.registry
  }

  func testPushPullBlobSmall() async throws {
    // Generate a simple blob
    let pushedBlob = Data("The quick brown fox jumps over the lazy dog".utf8)

    // Push it
    let pushedBlobDigest = try await registry.pushBlob(fromData: pushedBlob)
    XCTAssertEqual("sha256:d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592", pushedBlobDigest)

    // Pull it
    var pulledBlob = Data()
    try await registry.pullBlob(pushedBlobDigest) { data in
      pulledBlob.append(data)
    }

    // Ensure that both blobs are identical
    XCTAssertEqual(pushedBlob, pulledBlob)
  }

  func testPushPullBlobHugeInChunks() async throws {
    // Generate a large enough blob
    let fh = FileHandle(forReadingAtPath: "/dev/urandom")!
    let largeBlobToPush = try fh.read(upToCount: 768 * 1024 * 1024)!

    // Push it
    let largeBlobDigest = try await registry.pushBlob(fromData: largeBlobToPush, chunkSizeMb: 10)

    // Pull it
    var pulledLargeBlob = Data()
    try await registry.pullBlob(largeBlobDigest) { data in
      pulledLargeBlob.append(data)
    }

    // Ensure that both blobs are identical
    XCTAssertEqual(largeBlobToPush, pulledLargeBlob)
  }

  func testPushPullManifest() async throws {
    // Craft a basic config
    let configData = try OCIConfig().toJSON()
    let configDigest = try await registry.pushBlob(fromData: configData)

    // Craft a basic layer
    let layerData = Data("doesn't matter".utf8)
    let layerDigest = try await registry.pushBlob(fromData: layerData)

    // Craft a basic manifest and push it
    let manifest = OCIManifest(
      config: OCIManifestConfig(size: configData.count, digest: configDigest),
      layers: [
        OCIManifestLayer(mediaType: "application/octet-stream", size: layerData.count, digest: layerDigest)
      ]
    )
    let pushedManifestDigest = try await registry.pushManifest(reference: "latest", manifest: manifest)

    // Ensure that the manifest pulled by tag matches with the one pushed above
    let (pulledByTagManifest, _) = try await registry.pullManifest(reference: "latest")
    XCTAssertEqual(manifest, pulledByTagManifest)

    // Ensure that the manifest pulled by digest matches with the one pushed above
    let (pulledByDigestManifest, _) = try await registry.pullManifest(reference: "\(pushedManifestDigest)")
    XCTAssertEqual(manifest, pulledByDigestManifest)
  }
}

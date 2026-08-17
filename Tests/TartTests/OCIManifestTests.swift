import XCTest
@testable import tart

final class OCIManifestTests: XCTestCase {
  func testFlatDiskRepresentation() throws {
    let chunks = [chunk(mediaType: diskV2MediaType, suffix: "base-0")]
    let representation = try manifest(diskDescriptors: chunks).tartDiskRepresentation()

    XCTAssertEqual(representation, .flat(base: TartDiskFileGroup(kind: .base, chunks: chunks, contentDigest: nil)))
  }

  func testStackedDiskRepresentation() throws {
    let base = chunk(mediaType: diskV2MediaType, suffix: "base-0", diskFileDigest: "sha256:base")
    let overlay0 = chunk(mediaType: asifOverlayMediaType, suffix: "overlay-0", diskFileDigest: "sha256:overlay", chunkCount: 2)
    let overlay1 = chunk(mediaType: asifOverlayMediaType, suffix: "overlay-1")
    let representation = try manifest(diskDescriptors: [base, overlay0, overlay1]).tartDiskRepresentation()

    XCTAssertEqual(representation, .stacked(
      base: TartDiskFileGroup(kind: .base, chunks: [base], contentDigest: "sha256:base"),
      overlays: [TartDiskFileGroup(kind: .asifOverlay, chunks: [overlay0, overlay1], contentDigest: "sha256:overlay")]
    ))
  }

  func testDiskFileGroupUncompressedSize() {
    let first = chunk(mediaType: diskV2MediaType, suffix: "base-0")
    let second = chunk(mediaType: diskV2MediaType, suffix: "base-1")
    XCTAssertEqual(TartDiskFileGroup(kind: .base, chunks: [first, second], contentDigest: nil).uncompressedSize(), 2)

    var overflowing = first
    overflowing.annotations?[uncompressedSizeAnnotation] = String(UInt64.max)
    XCTAssertNil(TartDiskFileGroup(kind: .base, chunks: [overflowing, second], contentDigest: nil).uncompressedSize())
  }

  func testDiskContentDigests() throws {
    let flatBase = chunk(mediaType: diskV2MediaType, suffix: "flat", diskFileDigest: "sha256:flat")
    XCTAssertEqual(try manifest(diskDescriptors: [flatBase]).diskContentDigests(), ["sha256:flat"])

    let stackedBase = chunk(mediaType: diskV2MediaType, suffix: "base", diskFileDigest: "sha256:base")
    let overlay = chunk(
      mediaType: asifOverlayMediaType,
      suffix: "overlay",
      diskFileDigest: "sha256:overlay",
      chunkCount: 1
    )
    XCTAssertEqual(
      try manifest(diskDescriptors: [stackedBase, overlay]).diskContentDigests(),
      ["sha256:base", "sha256:overlay"]
    )
  }

  func testStackedRepresentationRequiresBaseDigest() throws {
    let base = chunk(mediaType: diskV2MediaType, suffix: "base-0")
    let overlay = chunk(mediaType: asifOverlayMediaType, suffix: "overlay-0", diskFileDigest: "sha256:overlay", chunkCount: 1)

    assertManifestError(
      .invalidDiskMetadata("a stacked base disk needs a whole-file content digest"),
      diskDescriptors: [base, overlay]
    )
  }

  func testBaseGroupRejectsMetadataAfterFirstChunk() throws {
    let base0 = chunk(mediaType: diskV2MediaType, suffix: "base-0", diskFileDigest: "sha256:base")
    let base1 = chunk(mediaType: diskV2MediaType, suffix: "base-1", diskFileDigest: "sha256:other-base")

    assertManifestError(
      .invalidDiskMetadata("base disk metadata must appear only on its first chunk"),
      diskDescriptors: [base0, base1]
    )
  }

  func testBaseGroupRejectsOverlayChunkCount() throws {
    let base = chunk(mediaType: diskV2MediaType, suffix: "base-0", diskFileDigest: "sha256:base", chunkCount: 1)

    assertManifestError(
      .invalidDiskMetadata("base disk metadata must appear only on its first chunk"),
      diskDescriptors: [base]
    )
  }

  func testOverlayGroupRequiresDigestAndChunkCount() throws {
    let base = chunk(mediaType: diskV2MediaType, suffix: "base-0", diskFileDigest: "sha256:base")
    let overlay = chunk(mediaType: asifOverlayMediaType, suffix: "overlay-0")

    assertManifestError(
      .invalidDiskMetadata("an ASIF overlay needs a content digest and chunk count"),
      diskDescriptors: [base, overlay]
    )
  }

  func testOverlayGroupRejectsInconsistentChunkCount() throws {
    let base = chunk(mediaType: diskV2MediaType, suffix: "base-0", diskFileDigest: "sha256:base")
    let overlay = chunk(mediaType: asifOverlayMediaType, suffix: "overlay-0", diskFileDigest: "sha256:overlay", chunkCount: 2)

    assertManifestError(
      .invalidDiskMetadata("ASIF overlay chunk count is invalid"),
      diskDescriptors: [base, overlay]
    )
  }

  func testDiskV2AfterOverlayIsRejected() throws {
    let base = chunk(mediaType: diskV2MediaType, suffix: "base-0", diskFileDigest: "sha256:base")
    let overlay = chunk(mediaType: asifOverlayMediaType, suffix: "overlay-0", diskFileDigest: "sha256:overlay", chunkCount: 2)
    let lateBase = chunk(mediaType: diskV2MediaType, suffix: "base-1")

    assertManifestError(
      .invalidLayout("ASIF overlay chunks must be contiguous"),
      diskDescriptors: [base, overlay, lateBase]
    )
  }

  func testChunkMetadataIsRequired() throws {
    var base = chunk(mediaType: diskV2MediaType, suffix: "base-0")
    base.annotations = nil

    assertManifestError(
      .invalidDiskMetadata("disk chunks need uncompressed size and content digest"),
      diskDescriptors: [base]
    )
  }

  func testCanonicalConfigAndNVRAMOrderIsRequired() throws {
    let disk = chunk(mediaType: diskV2MediaType, suffix: "base-0")
    let manifest = OCIManifest(
      config: OCIManifestConfig(size: 1, digest: "sha256:oci-config"),
      layers: [disk, configLayer(), nvramLayer()]
    )

    XCTAssertThrowsError(try manifest.tartDiskRepresentation()) { error in
      XCTAssertEqual(
        error as? OCIManifestValidationError,
        .invalidLayout("descriptors must be ordered as config, disk chunks, then NVRAM")
      )
    }
  }

  func testManifestBlockLayout() throws {
    var manifest = manifest(diskDescriptors: [chunk(mediaType: diskV2MediaType, suffix: "base-0")])
    manifest.annotations = [
      uncompressedDiskSizeAnnotation: "100000000000",
      diskBlockSizeAnnotation: "512",
    ]

    XCTAssertEqual(manifest.diskBlockSize(), 512)
    XCTAssertEqual(manifest.diskBlockCount(), 195312500)
  }

  func testManifestRejectsInexactDerivedBlockCount() throws {
    var manifest = manifest(diskDescriptors: [chunk(mediaType: diskV2MediaType, suffix: "base-0")])
    manifest.annotations = [
      uncompressedDiskSizeAnnotation: "513",
      diskBlockSizeAnnotation: "512",
    ]

    XCTAssertNil(manifest.diskBlockCount())
  }

  private func assertManifestError(_ expected: OCIManifestValidationError, diskDescriptors: [OCIManifestLayer]) {
    XCTAssertThrowsError(try manifest(diskDescriptors: diskDescriptors).tartDiskRepresentation()) { error in
      XCTAssertEqual(error as? OCIManifestValidationError, expected)
    }
  }

  private func manifest(diskDescriptors: [OCIManifestLayer]) -> OCIManifest {
    OCIManifest(
      config: OCIManifestConfig(size: 1, digest: "sha256:oci-config"),
      layers: [configLayer()] + diskDescriptors + [nvramLayer()]
    )
  }

  private func configLayer() -> OCIManifestLayer {
    OCIManifestLayer(mediaType: configMediaType, size: 1, digest: "sha256:tart-config")
  }

  private func nvramLayer() -> OCIManifestLayer {
    OCIManifestLayer(mediaType: nvramMediaType, size: 1, digest: "sha256:nvram")
  }

  private func chunk(mediaType: String, suffix: String, diskFileDigest: String? = nil, chunkCount: Int? = nil) -> OCIManifestLayer {
    var descriptor = OCIManifestLayer(
      mediaType: mediaType,
      size: 1,
      digest: "sha256:\(suffix)",
      uncompressedSize: 1,
      uncompressedContentDigest: "sha256:uncompressed-\(suffix)"
    )

    if let diskFileDigest {
      descriptor.annotations?[diskFileContentDigestAnnotation] = diskFileDigest
    }
    if let chunkCount {
      descriptor.annotations?[diskFileChunkCountAnnotation] = String(chunkCount)
    }

    return descriptor
  }
}

import Foundation

// OCI manifest and OCI config media types
let ociManifestMediaType = "application/vnd.oci.image.manifest.v1+json"
let ociConfigMediaType = "application/vnd.oci.image.config.v1+json"

// Layer media types
let configMediaType = "application/vnd.cirruslabs.tart.config.v1"
let diskV2MediaType = "application/vnd.cirruslabs.tart.disk.v2"
let asifOverlayMediaType = "application/vnd.cirruslabs.tart.disk.asif.overlay.v1"
let nvramMediaType = "application/vnd.cirruslabs.tart.nvram.v1"

// Manifest annotations
let uncompressedDiskSizeAnnotation = "org.cirruslabs.tart.uncompressed-disk-size"
let uploadTimeAnnotation = "org.cirruslabs.tart.upload-time"
let diskBlockSizeAnnotation = "org.cirruslabs.tart.disk.block-size"

// Manifest labels
let diskFormatLabel = "org.cirruslabs.tart.disk.format"

// Layer annotations
let uncompressedSizeAnnotation = "org.cirruslabs.tart.uncompressed-size"
let uncompressedContentDigestAnnotation = "org.cirruslabs.tart.uncompressed-content-digest"
let diskFileContentDigestAnnotation = "org.cirruslabs.tart.disk-file-content-digest"
let diskFileChunkCountAnnotation = "org.cirruslabs.tart.disk-file-chunk-count"

/// The OCI-layer descriptors whose Tart disk chunks reconstruct one complete
/// base disk or ASIF overlay.
struct TartDiskFileGroup: Equatable {
  enum Kind: Equatable {
    case base
    case asifOverlay
  }

  var kind: Kind
  var chunks: [OCIManifestLayer]
  /// Whole reconstructed-file digest. Existing flat manifests do not have
  /// this until a macOS 27 clone normalizes its local manifest copy.
  var contentDigest: String?

  /// Expected size of the complete disk file reconstructed from these chunks.
  func uncompressedSize() -> UInt64? {
    var result: UInt64 = 0
    for chunk in chunks {
      guard let size = chunk.uncompressedSize() else {
        return nil
      }

      let addition = result.addingReportingOverflow(size)
      guard !addition.overflow else {
        return nil
      }
      result = addition.partialValue
    }

    return result
  }
}

enum TartDiskRepresentation: Equatable {
  case flat(base: TartDiskFileGroup)
  case stacked(base: TartDiskFileGroup, overlays: [TartDiskFileGroup])
}

enum OCIManifestValidationError: Error, Equatable {
  case invalidLayout(String)
  case invalidDiskMetadata(String)
}

struct OCIManifest: Codable, Equatable {
  var schemaVersion: Int = 2
  var mediaType: String = ociManifestMediaType
  var config: OCIManifestConfig
  var layers: [OCIManifestLayer] = Array()
  var annotations: Dictionary<String, String>?

  init(config: OCIManifestConfig, layers: [OCIManifestLayer], uncompressedDiskSize: UInt64? = nil, uploadDate: Date? = nil) {
    self.config = config
    self.layers = layers

    var annotations: [String: String] = [:]

    if let uncompressedDiskSize = uncompressedDiskSize {
      annotations[uncompressedDiskSizeAnnotation] = String(uncompressedDiskSize)
    }

    if let uploadDate = uploadDate {
      annotations[uploadTimeAnnotation] = uploadDate.toISO()
    }

    self.annotations = annotations
  }

  init(fromJSON: Data) throws {
    self = try Config.jsonDecoder().decode(Self.self, from: fromJSON)
  }

  func toJSON() throws -> Data {
    try Config.jsonEncoder().encode(self)
  }

  func digest() throws -> String {
    try Digest.hash(toJSON())
  }

  func uncompressedDiskSize() -> UInt64? {
    guard let value = annotations?[uncompressedDiskSizeAnnotation] else {
      return nil
    }

    return UInt64(value)
  }

  /// Parse Tart's canonical `config -> disk descriptors -> NVRAM` order.
  /// A stacked image has a leading `disk.v2` base run followed by one or more
  /// contiguous ASIF overlay chunk groups.
  func tartDiskRepresentation() throws -> TartDiskRepresentation {
    guard layers.filter({ $0.mediaType == configMediaType }).count == 1 else {
      throw OCIManifestValidationError.invalidLayout("manifest must contain exactly one Tart config descriptor")
    }
    guard layers.filter({ $0.mediaType == nvramMediaType }).count == 1 else {
      throw OCIManifestValidationError.invalidLayout("manifest must contain exactly one NVRAM descriptor")
    }
    guard layers.first?.mediaType == configMediaType,
          layers.last?.mediaType == nvramMediaType else {
      throw OCIManifestValidationError.invalidLayout("descriptors must be ordered as config, disk chunks, then NVRAM")
    }

    let diskDescriptors = Array(layers.dropFirst().dropLast())
    guard !diskDescriptors.isEmpty else {
      throw OCIManifestValidationError.invalidLayout("manifest has no disk chunks")
    }

    let baseChunkCount = diskDescriptors.prefix { $0.mediaType == diskV2MediaType }.count
    guard baseChunkCount > 0 else {
      throw OCIManifestValidationError.invalidLayout("disk chunks must start with a disk.v2 base")
    }

    let baseChunks = Array(diskDescriptors.prefix(baseChunkCount))
    try validateChunkMetadata(baseChunks)
    guard baseChunks.first?.diskFileChunkCount() == nil,
          baseChunks.dropFirst().allSatisfy({
            $0.diskFileContentDigest() == nil && $0.diskFileChunkCount() == nil
          }) else {
      throw OCIManifestValidationError.invalidDiskMetadata("base disk metadata must appear only on its first chunk")
    }
    let base = TartDiskFileGroup(
      kind: .base,
      chunks: baseChunks,
      contentDigest: baseChunks.first?.diskFileContentDigest()
    )

    guard baseChunkCount < diskDescriptors.count else {
      return .flat(base: base)
    }

    guard base.contentDigest != nil else {
      throw OCIManifestValidationError.invalidDiskMetadata("a stacked base disk needs a whole-file content digest")
    }

    var overlays: [TartDiskFileGroup] = []
    var index = baseChunkCount

    while index < diskDescriptors.count {
      let first = diskDescriptors[index]
      guard first.mediaType == asifOverlayMediaType else {
        throw OCIManifestValidationError.invalidLayout("unsupported disk chunk media type: \(first.mediaType)")
      }
      guard let contentDigest = first.diskFileContentDigest(),
            let chunkCount = first.diskFileChunkCount() else {
        throw OCIManifestValidationError.invalidDiskMetadata("an ASIF overlay needs a content digest and chunk count")
      }
      guard chunkCount > 0, index + chunkCount <= diskDescriptors.count else {
        throw OCIManifestValidationError.invalidDiskMetadata("ASIF overlay chunk count is invalid")
      }

      let chunks = Array(diskDescriptors[index..<(index + chunkCount)])
      guard chunks.allSatisfy({ $0.mediaType == asifOverlayMediaType }) else {
        throw OCIManifestValidationError.invalidLayout("ASIF overlay chunks must be contiguous")
      }
      guard chunks.dropFirst().allSatisfy({ $0.diskFileContentDigest() == nil && $0.diskFileChunkCount() == nil }) else {
        throw OCIManifestValidationError.invalidDiskMetadata("ASIF overlay metadata must appear only on its first chunk")
      }
      try validateChunkMetadata(chunks)

      overlays.append(TartDiskFileGroup(kind: .asifOverlay, chunks: chunks, contentDigest: contentDigest))
      index += chunkCount
    }

    return .stacked(base: base, overlays: overlays)
  }

  /// Returns content-store digests needed to reconstruct this disk stack.
  func diskContentDigests() throws -> [String] {
    switch try tartDiskRepresentation() {
    case .flat(let base):
      return base.contentDigest.map { [$0] } ?? []
    case .stacked(let base, let overlays):
      return ([base] + overlays).compactMap(\.contentDigest)
    }
  }

  private func validateChunkMetadata(_ chunks: [OCIManifestLayer]) throws {
    guard chunks.allSatisfy({ $0.uncompressedSize() != nil && $0.uncompressedContentDigest() != nil }) else {
      throw OCIManifestValidationError.invalidDiskMetadata("disk chunks need uncompressed size and content digest")
    }
  }

  func diskBlockSize() -> UInt64? {
    annotations?[diskBlockSizeAnnotation].flatMap(UInt64.init)
  }

  func diskBlockCount() -> UInt64? {
    guard let diskSize = uncompressedDiskSize(),
          let blockSize = diskBlockSize(),
          blockSize > 0,
          diskSize.isMultiple(of: blockSize) else {
      return nil
    }

    return diskSize / blockSize
  }
}

struct OCIConfig: Codable {
  var architecture: Architecture = .arm64
  var os: OS = .darwin
  var config: ConfigContainer?

  struct ConfigContainer: Codable {
    var Labels: [String: String]?
  }

  func toJSON() throws -> Data {
    try Config.jsonEncoder().encode(self)
  }
}

struct OCIManifestConfig: Codable, Equatable {
  var mediaType: String = ociConfigMediaType
  var size: Int
  var digest: String
}

struct OCIManifestLayer: Codable, Equatable, Hashable {
  var mediaType: String
  var size: Int
  var digest: String
  var annotations: Dictionary<String, String>?

  init(mediaType: String, size: Int, digest: String, uncompressedSize: UInt64? = nil, uncompressedContentDigest: String? = nil) {
    self.mediaType = mediaType
    self.size = size
    self.digest = digest

    var annotations: [String: String] = [:]

    if let uncompressedSize = uncompressedSize {
      annotations[uncompressedSizeAnnotation] = String(uncompressedSize)
    }

    if let uncompressedContentDigest = uncompressedContentDigest {
      annotations[uncompressedContentDigestAnnotation] = uncompressedContentDigest
    }

    self.annotations = annotations
  }

  func uncompressedSize() -> UInt64? {
    guard let value = annotations?[uncompressedSizeAnnotation] else {
      return nil
    }

    return UInt64(value)
  }

  func uncompressedContentDigest() -> String? {
    annotations?[uncompressedContentDigestAnnotation]
  }

  func diskFileContentDigest() -> String? {
    annotations?[diskFileContentDigestAnnotation]
  }

  func diskFileChunkCount() -> Int? {
    annotations?[diskFileChunkCountAnnotation].flatMap(Int.init)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    return lhs.digest == rhs.digest
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(digest)
  }
}

struct Descriptor: Equatable {
  var size: Int
  var digest: String
}

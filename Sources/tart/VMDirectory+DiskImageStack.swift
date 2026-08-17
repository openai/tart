import Foundation

extension VMDirectory {
  /// Returns content-store digests needed to reconstruct this VM's disk stack.
  func diskContentDigests() throws -> [String] {
    let manifest = try OCIManifest(fromJSON: Data(contentsOf: manifestURL))
    return try manifest.diskContentDigests()
  }

  func diskImageStack(contentStore providedStore: ContentStore? = nil) throws -> DiskImageStack {
    let manifest = try OCIManifest(fromJSON: Data(contentsOf: manifestURL))
    let base: TartDiskFileGroup
    let overlays: [TartDiskFileGroup]

    switch try manifest.tartDiskRepresentation() {
    case .flat(let pinnedBase) where pinnedBase.contentDigest != nil:
      base = pinnedBase
      overlays = []
    case .stacked(let stackedBase, let stackedOverlays):
      base = stackedBase
      overlays = stackedOverlays
    default:
      throw RuntimeError.VMConfigurationError("VM is missing its disk image metadata")
    }
    guard let blockSize = manifest.diskBlockSize(),
          let blockCount = manifest.diskBlockCount() else {
      throw DiskImageStackError.invalidBlockLayout("disk image metadata is missing block layout")
    }

    let contentStore = try providedStore ?? ContentStore()
    let baseURL = try diskImageURL(for: base, contentStore: contentStore)
    let immutableOverlayURLs = try overlays.map { try diskImageURL(for: $0, contentStore: contentStore) }
    let config = try VMConfig(fromURL: configURL)

    return DiskImageStack(
      baseURL: baseURL,
      baseFormat: config.diskFormat,
      immutableOverlayURLs: immutableOverlayURLs,
      writableOverlayURL: overlayURL,
      blockSize: blockSize,
      blockCount: blockCount
    )
  }

  func cloneStacked(
    to destination: VMDirectory,
    copyWritableOverlay: Bool,
    generateMAC: Bool,
    contentStore: ContentStore? = nil
  ) throws {
    let contentStore = try contentStore ?? ContentStore()
    try contentStore.withPruneLock {
      try FileManager.default.copyItem(at: configURL, to: destination.configURL)
      try FileManager.default.copyItem(at: nvramURL, to: destination.nvramURL)
      try FileManager.default.copyItem(at: manifestURL, to: destination.manifestURL)

      if copyWritableOverlay {
        try FileManager.default.copyItem(at: overlayURL, to: destination.overlayURL)
      }
    }

    if !copyWritableOverlay {
      try destination.diskImageStack(contentStore: contentStore).createWritableOverlay()
    }

    if generateMAC {
      try destination.regenerateMACAddress()
    }
  }

  func cloneAsStackedBase(
    to destination: VMDirectory,
    generateMAC: Bool,
    contentStore providedStore: ContentStore? = nil
  ) throws {
    let config = try VMConfig(fromURL: configURL)
    let blockLayout = try DiskImageStack.baseBlockLayout(at: diskURL, expectedFormat: config.diskFormat)
    let contentDigest = try Digest.hash(diskURL)
    let contentStore = try providedStore ?? ContentStore()

    var manifest = try OCIManifest(fromJSON: Data(contentsOf: manifestURL))
    guard case .flat = try manifest.tartDiskRepresentation() else {
      throw RuntimeError.VMConfigurationError("--stacked cannot use an image that already has a stacked disk")
    }

    guard let firstDiskIndex = manifest.layers.firstIndex(where: { $0.mediaType == diskV2MediaType }) else {
      throw OCIManifestValidationError.invalidLayout("manifest must contain at least one disk chunk")
    }

    var baseAnnotations = manifest.layers[firstDiskIndex].annotations ?? [:]
    baseAnnotations[diskFileContentDigestAnnotation] = contentDigest
    manifest.layers[firstDiskIndex].annotations = baseAnnotations
    let diskSize = blockLayout.blockSize.multipliedReportingOverflow(by: blockLayout.blockCount)
    guard !diskSize.overflow else {
      throw DiskImageStackError.invalidBlockLayout("stacked disk block layout overflows UInt64")
    }
    var annotations = manifest.annotations ?? [:]
    annotations[diskBlockSizeAnnotation] = String(blockLayout.blockSize)
    annotations[uncompressedDiskSizeAnnotation] = String(diskSize.partialValue)
    manifest.annotations = annotations

    try FileManager.default.copyItem(at: configURL, to: destination.configURL)
    try FileManager.default.copyItem(at: nvramURL, to: destination.nvramURL)
    try contentStore.withPruneLock {
      try manifest.toJSON().write(to: destination.manifestURL)
    }

    // Publish the temporary VM's manifest before installing the shared base.
    // Reference-aware pruning includes in-progress manifests, so the content
    // cannot be collected in the window before this VM is moved into place.
    if try contentStore.contentURLIfPresent(for: contentDigest) == nil {
      let temporaryURL = try contentStore.temporaryContentURL(for: contentDigest)
      do {
        try FileManager.default.copyItem(at: diskURL, to: temporaryURL)
        _ = try contentStore.install(temporaryURL, contentDigest: contentDigest)
      } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        throw error
      }
    }

    try destination.diskImageStack(contentStore: contentStore).createWritableOverlay()

    if generateMAC {
      try destination.regenerateMACAddress()
    }
  }

  private func diskImageURL(for group: TartDiskFileGroup, contentStore: ContentStore) throws -> URL {
    guard let contentDigest = group.contentDigest else {
      throw OCIManifestValidationError.invalidDiskMetadata("stacked disk files need a whole-file content digest")
    }
    // Pull/install verifies immutable content before publishing it. Clone and
    // run use the trusted content-addressed entry without rereading a possibly
    // very large disk file, matching Tart's existing disk.img behavior.
    guard let url = try contentStore.contentURLIfPresent(for: contentDigest) else {
      throw RuntimeError.VMMissingFiles("VM is missing cached disk content \(contentDigest)")
    }

    return url
  }
}

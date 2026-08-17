import Compression
import Foundation
import OpenTelemetryApi

let legacyDiskV1MediaType = "application/vnd.cirruslabs.tart.disk.v1"

enum OCIError: Error {
  case ShouldBeExactlyOneLayer
  case FailedToCreateVmFile
  case LayerIsMissingUncompressedSizeAnnotation
  case LayerIsMissingUncompressedDigestAnnotation
}

extension VMDirectory {
  func pullFromRegistry(registry: Registry, manifest: OCIManifest, concurrency: UInt, localLayerCache: LocalLayerCache?, deduplicate: Bool) async throws {
    // Pull VM's config file layer and store it as the local config file.
    let configLayers = manifest.layers.filter {
      $0.mediaType == configMediaType
    }
    if configLayers.count != 1 {
      throw OCIError.ShouldBeExactlyOneLayer
    }
    if !FileManager.default.createFile(atPath: configURL.path, contents: nil) {
      throw OCIError.FailedToCreateVmFile
    }
    let configFile = try FileHandle(forWritingTo: configURL)
    try await registry.pullBlob(configLayers.first!.digest) { data in
      try configFile.write(contentsOf: data)
    }
    try configFile.close()

    // Pull VM's disk chunks and decompress them into complete disk files.
    if manifest.layers.contains(where: { $0.mediaType == legacyDiskV1MediaType }) {
      throw RuntimeError.Generic("Pulling OCI images with legacy disk media type \(legacyDiskV1MediaType) is no longer supported, please re-push the image using a current Tart version")
    }

    let diskRepresentation = try manifest.tartDiskRepresentation()
    let diskChunks: [OCIManifestLayer]

    switch diskRepresentation {
    case .flat(let base):
      diskChunks = base.chunks
    case .stacked(let base, let overlays):
      diskChunks = base.chunks + overlays.flatMap(\.chunks)
    }

    let diskCompressedSize = diskChunks.map { Int64($0.size) }.reduce(0, +)
    OpenTelemetry.instance.contextProvider.activeSpan?.setAttribute(
      key: "compressed_disk_size_bytes",
      value: .int(Int(diskCompressedSize))
    )

    let prettyDiskSize = String(format: "%.1f", Double(diskCompressedSize) / 1_000_000_000.0)
    defaultLogger.appendNewLine("pulling disk (\(prettyDiskSize) GB compressed)...")

    let progress = Progress(totalUnitCount: diskCompressedSize)
    ProgressObserver(progress).log(defaultLogger)

    do {
      switch diskRepresentation {
      case .flat(let base):
        try await DiskV2.pull(registry: registry, diskLayers: base.chunks, diskURL: diskURL,
                              concurrency: concurrency, progress: progress,
                              localLayerCache: localLayerCache,
                              deduplicate: deduplicate)

        if deduplicate, let llc = localLayerCache {
          // set custom attribute to remember deduplicated bytes
          diskURL.setDeduplicatedBytes(llc.deduplicatedBytes)
        }
      case .stacked(let base, let overlays):
        // The deterministic resumable directory may contain a partial
        // disk.img from an interrupted pull while this tag was standalone. A
        // cached stacked image must not retain that file or it is mistaken for
        // a standalone VM after the pull is moved into cache.
        if FileManager.default.fileExists(atPath: diskURL.path) {
          try FileManager.default.removeItem(at: diskURL)
        }

        let contentStore = try ContentStore()

        for group in [base] + overlays {
          _ = try await pullDiskFile(
            registry: registry,
            group: group,
            contentStore: contentStore,
            concurrency: concurrency,
            progress: progress
          )
        }
      }
    } catch let error where error is FilterError {
      throw RuntimeError.PullFailed("failed to decompress disk: \(error.localizedDescription)")
    }

    // Pull VM's NVRAM file layer and store it in an NVRAM file
    defaultLogger.appendNewLine("pulling NVRAM...")

    let nvramLayers = manifest.layers.filter {
      $0.mediaType == nvramMediaType
    }
    if nvramLayers.count != 1 {
      throw OCIError.ShouldBeExactlyOneLayer
    }
    if !FileManager.default.createFile(atPath: nvramURL.path, contents: nil) {
      throw OCIError.FailedToCreateVmFile
    }
    let nvram = try FileHandle(forWritingTo: nvramURL)
    try await registry.pullBlob(nvramLayers.first!.digest) { data in
      try nvram.write(contentsOf: data)
    }
    try nvram.close()
  }

  /// Reconstructs one complete immutable base disk or published ASIF overlay
  /// from its Tart disk chunks, unless the shared content store already has a
  /// size-matching copy.
  private func pullDiskFile(
    registry: Registry,
    group: TartDiskFileGroup,
    contentStore: ContentStore,
    concurrency: UInt,
    progress: Progress
  ) async throws -> URL {
    guard let contentDigest = group.contentDigest else {
      throw OCIManifestValidationError.invalidDiskMetadata("stacked disk files need a whole-file content digest")
    }

    // Pulls for the same semantic disk file share a stable resumable path so
    // DiskV2 can resume after a transient failure. Serialize writers before
    // rechecking the final entry to avoid racing on that shared path.
    let lock = try FileLock(lockURL: contentStore.lockURL(for: contentDigest))
    try lock.lock()
    defer { try? lock.unlock() }

    if let existingURL = try contentStore.contentURLIfPresent(for: contentDigest),
       let actualSize = UInt64(exactly: try existingURL.sizeBytes()),
       let expectedSize = group.uncompressedSize(),
       actualSize == expectedSize {
      progress.completedUnitCount += group.chunks.reduce(0) { $0 + Int64($1.size) }
      return existingURL
    }

    let resumableURL = try contentStore.resumableContentURL(for: contentDigest)
    try await DiskV2.pull(
      registry: registry,
      diskLayers: group.chunks,
      diskURL: resumableURL,
      concurrency: concurrency,
      progress: progress
    )

    return try contentStore.install(resumableURL, contentDigest: contentDigest)
  }

  func pushToRegistry(registry: Registry, references: [String], chunkSizeMb: Int, concurrency: UInt, labels: [String: String] = [:]) async throws -> (name: RemoteName, manifest: OCIManifest) {
    var layers = Array<OCIManifestLayer>()

    // Read VM's config and push it as blob
    let config = try VMConfig(fromURL: configURL)

    // Add disk format label automatically
    var labels = labels
    labels[diskFormatLabel] = config.diskFormat.rawValue
    let configJSON = try JSONEncoder().encode(config)
    defaultLogger.appendNewLine("pushing config...")
    let configDigest = try await registry.pushBlob(fromData: configJSON, chunkSizeMb: chunkSizeMb)
    layers.append(OCIManifestLayer(mediaType: configMediaType, size: configJSON.count, digest: configDigest))

    let (diskLayers, diskAnnotations) = try await pushDiskLayers(
      registry: registry,
      chunkSizeMb: chunkSizeMb,
      concurrency: concurrency
    )
    layers.append(contentsOf: diskLayers)

    // Read VM's NVRAM and push it as blob
    defaultLogger.appendNewLine("pushing NVRAM...")

    let nvram = try FileHandle(forReadingFrom: nvramURL).readToEnd()!
    let nvramDigest = try await registry.pushBlob(fromData: nvram, chunkSizeMb: chunkSizeMb)
    layers.append(OCIManifestLayer(mediaType: nvramMediaType, size: nvram.count, digest: nvramDigest))

    // Craft a stub OCI config for Docker Hub compatibility
    let ociConfigContainer = OCIConfig.ConfigContainer(Labels: labels)
    let ociConfigJSON = try OCIConfig(architecture: config.arch, os: config.os, config: ociConfigContainer).toJSON()
    let ociConfigDigest = try await registry.pushBlob(fromData: ociConfigJSON, chunkSizeMb: chunkSizeMb)
    var manifest = OCIManifest(
      config: OCIManifestConfig(size: ociConfigJSON.count, digest: ociConfigDigest),
      layers: layers
    )
    var annotations = diskAnnotations
    annotations[uploadTimeAnnotation] = Date().toISO()
    manifest.annotations = annotations
    // Manifest
    for reference in references {
      defaultLogger.appendNewLine("pushing manifest for \(reference)...")

      _ = try await registry.pushManifest(reference: reference, manifest: manifest)
    }

    let pushedReference = Reference(digest: try manifest.digest())
    let name = RemoteName(host: registry.host!, namespace: registry.namespace, reference: pushedReference)
    return (name, manifest)
  }

  /// Builds the disk portion of the manifest. Registry transport is shared
  /// for standalone and stacked VMs; only their local disk representation
  /// determines which descriptors need to be uploaded or reused.
  private func pushDiskLayers(
    registry: Registry,
    chunkSizeMb: Int,
    concurrency: UInt
  ) async throws -> ([OCIManifestLayer], [String: String]) {
    guard isStackedVM else {
      let diskSize = try FileManager.default.attributesOfItem(atPath: diskURL.path)[.size] as! Int64
      defaultLogger.appendNewLine("pushing disk... this will take a while...")
      let progress = Progress(totalUnitCount: diskSize)
      ProgressObserver(progress).log(defaultLogger)

      let layers = try await DiskV2.push(
        diskURL: diskURL,
        mediaType: diskV2MediaType,
        registry: registry,
        chunkSizeMb: chunkSizeMb,
        concurrency: concurrency,
        progress: progress
      )
      return (layers, [uncompressedDiskSizeAnnotation: String(diskSize)])
    }

    let localManifest = try OCIManifest(fromJSON: Data(contentsOf: manifestURL))
    // pushToRegistry() reads config.json before reaching this point. Closing
    // that read descriptor can release the caller's fcntl PID lock, so take a
    // fresh lock before hashing, uploading, and inspecting the writable overlay.
    let stackedDiskLock = try lock()
    guard try stackedDiskLock.trylock() else {
      throw RuntimeError.VMIsRunning(name)
    }
    defer { try? stackedDiskLock.unlock() }

    let inheritedGroups: [TartDiskFileGroup]
    switch try localManifest.tartDiskRepresentation() {
    case .flat(let base) where base.contentDigest != nil:
      inheritedGroups = [base]
    case .stacked(let base, let overlays):
      inheritedGroups = [base] + overlays
    default:
      throw RuntimeError.VMConfigurationError("stacked VM is missing a pinned disk stack")
    }

    let contentStore = try ContentStore()
    var layers: [OCIManifestLayer] = []
    for group in inheritedGroups {
      layers.append(contentsOf: try await descriptorsForCachedDiskFile(
        group,
        contentStore: contentStore,
        registry: registry,
        chunkSizeMb: chunkSizeMb,
        concurrency: concurrency
      ))
    }

    let overlaySize = try FileManager.default.attributesOfItem(atPath: overlayURL.path)[.size] as! Int64
    defaultLogger.appendNewLine("pushing overlay...")
    let progress = Progress(totalUnitCount: overlaySize)
    ProgressObserver(progress).log(defaultLogger)
    let contentDigest = try Digest.hash(overlayURL)
    let chunks = try await DiskV2.push(
      diskURL: overlayURL,
      mediaType: asifOverlayMediaType,
      registry: registry,
      chunkSizeMb: chunkSizeMb,
      concurrency: concurrency,
      progress: progress
    )
    layers.append(contentsOf: annotatedChunks(chunks, kind: .asifOverlay, contentDigest: contentDigest))

    let blockLayout = try DiskImageStack.diskImageBlockLayout(at: overlayURL)
    let diskSize = blockLayout.blockSize.multipliedReportingOverflow(by: blockLayout.blockCount)
    guard !diskSize.overflow else {
      throw DiskImageStackError.invalidBlockLayout("stacked disk block layout overflows UInt64")
    }

    var annotations = localManifest.annotations ?? [:]
    annotations[diskBlockSizeAnnotation] = String(blockLayout.blockSize)
    annotations[uncompressedDiskSizeAnnotation] = String(diskSize.partialValue)

    return (layers, annotations)
  }

  /// Returns transport descriptors for an immutable disk file. If the
  /// target registry lacks the original blobs, recreate them from the local
  /// content store.
  private func descriptorsForCachedDiskFile(
    _ group: TartDiskFileGroup,
    contentStore: ContentStore,
    registry: Registry,
    chunkSizeMb: Int,
    concurrency: UInt
  ) async throws -> [OCIManifestLayer] {
    guard let contentDigest = group.contentDigest else {
      throw RuntimeError.VMConfigurationError("stacked VM is missing a pinned disk file digest")
    }

    var allChunksExist = true
    for chunk in group.chunks {
      if try await !registry.blobExists(chunk.digest) {
        allChunksExist = false
        break
      }
    }
    if allChunksExist {
      return group.chunks
    }

    // Rebuilding transport blobs republishes this file under the pinned
    // whole-file digest, so validate the cached bytes at this boundary.
    guard let contentURL = try contentStore.existingContentURL(for: contentDigest) else {
      throw RuntimeError.VMMissingFiles("stacked VM is missing cached disk content \(contentDigest)")
    }
    let contentSize = try FileManager.default.attributesOfItem(atPath: contentURL.path)[.size] as! Int64
    let progress = Progress(totalUnitCount: contentSize)
    let mediaType = group.kind == .base ? diskV2MediaType : asifOverlayMediaType
    let chunks = try await DiskV2.push(
      diskURL: contentURL,
      mediaType: mediaType,
      registry: registry,
      chunkSizeMb: chunkSizeMb,
      concurrency: concurrency,
      progress: progress
    )

    return annotatedChunks(chunks, kind: group.kind, contentDigest: contentDigest)
  }

  private func annotatedChunks(
    _ chunks: [OCIManifestLayer],
    kind: TartDiskFileGroup.Kind,
    contentDigest: String
  ) -> [OCIManifestLayer] {
    guard !chunks.isEmpty else {
      return chunks
    }

    var chunks = chunks
    var annotations = chunks[0].annotations ?? [:]
    annotations[diskFileContentDigestAnnotation] = contentDigest
    if kind == .asifOverlay {
      annotations[diskFileChunkCountAnnotation] = String(chunks.count)
    }
    chunks[0].annotations = annotations

    return chunks
  }
}

extension Progress {
  func percentage() -> String {
    String(Int(100 * fractionCompleted)) + "%"
  }
}

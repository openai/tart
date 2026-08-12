import Foundation
import OpenTelemetryApi
import Retry

class VMStorageOCI: PrunableStorage {
  let baseURL: URL

  init() throws {
    baseURL = try Config().tartCacheDir.appendingPathComponent("OCIs", isDirectory: true)
  }

  private func vmURL(_ name: RemoteName) -> URL {
    baseURL.appendingRemoteName(name)
  }

  private func hostDirectoryURL(_ name: RemoteName) -> URL {
    baseURL.appendingHost(name)
  }

  func exists(_ name: RemoteName) -> Bool {
    VMDirectory(baseURL: vmURL(name)).isCachedImage
  }

  /// Whether clone can use a cached image without pulling. Standalone images keep
  /// Tart's existing structural check. Stacked cached images cheaply require every
  /// immutable file with its expected length; explicit pull remains the path
  /// that hashes content and repairs same-sized corruption.
  func hasUsableCachedImageForClone(_ name: RemoteName, requireManifest: Bool = false) throws -> Bool {
    guard exists(name) else {
      return false
    }

    let vmDir = VMDirectory(baseURL: vmURL(name))
    if requireManifest && !FileManager.default.fileExists(atPath: vmDir.manifestURL.path) {
      return false
    }
    guard vmDir.isStackedCachedImage else {
      return true
    }

    let manifest = try OCIManifest(fromJSON: Data(contentsOf: vmDir.manifestURL))
    guard case .stacked(let base, let overlays) = try manifest.tartDiskRepresentation() else {
      return true
    }

    let contentStore = try ContentStore()
    for group in [base] + overlays {
      guard let contentDigest = group.contentDigest,
            let contentURL = try contentStore.contentURLIfPresent(for: contentDigest) else {
        return false
      }

      var expectedSize: UInt64 = 0
      for chunk in group.chunks {
        guard let uncompressedSize = chunk.uncompressedSize() else {
          return false
        }
        let addition = expectedSize.addingReportingOverflow(uncompressedSize)
        guard !addition.overflow else {
          return false
        }
        expectedSize = addition.partialValue
      }

      guard let actualSize = UInt64(exactly: try contentURL.sizeBytes()),
            actualSize == expectedSize else {
        return false
      }
    }

    return true
  }

  /// Whether a cached image is complete enough for `pull` to return without
  /// repairing it. Standalone images keep Tart's existing structural cache-hit
  /// behavior; stacked cached images additionally need every immutable disk file in
  /// the shared content store.
  func hasCompleteCachedImage(_ name: RemoteName, manifest: OCIManifest) throws -> Bool {
    guard exists(name) else {
      return false
    }

    guard let missingGroups = try missingStackedDiskFileGroups(for: manifest) else {
      return true
    }

    return missingGroups.isEmpty
  }

  /// The lock-free pull fast path is only useful for a tag that already
  /// points at this digest. New or retargeted tags validate once after taking
  /// the host lock instead of hashing a large stack twice.
  func hasCompleteLinkedImage(_ name: RemoteName, digestName: RemoteName, manifest: OCIManifest) throws -> Bool {
    guard exists(name), linked(from: name, to: digestName) else {
      return false
    }

    return try hasCompleteCachedImage(digestName, manifest: manifest)
  }

  /// Bytes that this pull may need to materialize locally. For stacked images
  /// this is the sum of only the missing complete disk files, not the final
  /// guest-visible disk block layout.
  func requiredDiskStorageBytes(for manifest: OCIManifest) throws -> UInt64? {
    guard let missingGroups = try missingStackedDiskFileGroups(for: manifest) else {
      return manifest.uncompressedDiskSize()
    }

    var total: UInt64 = 0
    for group in missingGroups {
      for chunk in group.chunks {
        guard let uncompressedSize = chunk.uncompressedSize() else {
          throw OCIManifestValidationError.invalidDiskMetadata("disk chunks need uncompressed size and content digest")
        }
        let addition = total.addingReportingOverflow(uncompressedSize)
        guard !addition.overflow else {
          throw RuntimeError.PullFailed("stacked disk storage size overflows UInt64")
        }
        total = addition.partialValue
      }
    }

    return total
  }

  func digest(_ name: RemoteName) throws -> String {
    let digest = vmURL(name).resolvingSymlinksInPath().lastPathComponent

    if !digest.starts(with: "sha256:") {
      throw RuntimeError.OCIStorageError("\(name) is not a digest and doesn't point to a digest")
    }

    return digest
  }

  func open(_ name: RemoteName, _ accessDate: Date = Date()) throws -> VMDirectory {
    let vmDir = VMDirectory(baseURL: vmURL(name))

    try vmDir.validateCachedImage(userFriendlyName: name.description)

    try vmDir.baseURL.updateAccessDate(accessDate)

    return vmDir
  }

  func create(_ name: RemoteName, overwrite: Bool = false) throws -> VMDirectory {
    let vmDir = VMDirectory(baseURL: vmURL(name))

    if !overwrite && vmDir.isCachedImage {
      throw RuntimeError.VMDirectoryAlreadyInitialized("VM directory is already initialized, preventing overwrite")
    }

    try vmDir.initialize(overwrite: overwrite)

    return vmDir
  }

  /// Materialize the digest-addressed cached image for an image Tart just
  /// pushed, without routing its own local data back through the registry.
  func populate(_ name: RemoteName, from source: VMDirectory, manifest: OCIManifest) throws {
    if try hasCompleteCachedImage(name, manifest: manifest) {
      return
    }

    let vmDir = try create(name, overwrite: exists(name))

    if source.isStackedVM {
      guard case .stacked(_, let overlays) = try manifest.tartDiskRepresentation(),
            let contentDigest = overlays.last?.contentDigest else {
        throw RuntimeError.VMConfigurationError("pushed image is missing its writable ASIF overlay")
      }

      // The pushed top overlay becomes immutable in the cached image. Keep a
      // semantic copy so later clones do not need to fetch it back.
      let contentStore = try ContentStore()
      if try contentStore.existingContentURL(for: contentDigest) == nil {
        let temporaryURL = try contentStore.temporaryContentURL(for: contentDigest)
        do {
          try FileManager.default.copyItem(at: source.overlayURL, to: temporaryURL)
          _ = try contentStore.install(temporaryURL, contentDigest: contentDigest)
        } catch {
          try? FileManager.default.removeItem(at: temporaryURL)
          throw error
        }
      }

      try FileManager.default.copyItem(at: source.configURL, to: vmDir.configURL)
      try FileManager.default.copyItem(at: source.nvramURL, to: vmDir.nvramURL)
    } else {
      try source.clone(to: vmDir, generateMAC: false)
    }

    // Keep the exact manifest Tart submitted so tag links and later pushes
    // refer to the same digest-addressed cached image.
    try manifest.toJSON().write(to: vmDir.manifestURL)
  }

  func move(_ name: RemoteName, from: VMDirectory) throws{
    let targetURL = vmURL(name)

    // Pre-create intermediate directories (e.g. creates ~/.tart/cache/OCIs/github.com/org/repo/
    // for github.com/org/repo:latest)
    try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)

    _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: from.baseURL)
  }

  func delete(_ name: RemoteName) throws {
    try FileManager.default.removeItem(at: vmURL(name))
    try gc()
  }

  func gc() throws {
    var refCounts = Dictionary<URL, UInt>()

    guard let enumerator = FileManager.default.enumerator(at: baseURL,
                                                          includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
      return
    }

    for case let foundURL as URL in enumerator {
      let isSymlink = try foundURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink!

      // Perform garbage collection for tag-based images
      // with broken outgoing references
      if isSymlink && foundURL == foundURL.resolvingSymlinksInPath() {
        try FileManager.default.removeItem(at: foundURL)
        continue
      }

      let vmDir = VMDirectory(baseURL: foundURL.resolvingSymlinksInPath())
      if !vmDir.isCachedImage {
        continue
      }

      refCounts[vmDir.baseURL] = (refCounts[vmDir.baseURL] ?? 0) + (isSymlink ? 1 : 0)
    }

    // Perform garbage collection for digest-based images
    // with no incoming references
    for (baseURL, incRefCount) in refCounts {
      let vmDir = VMDirectory(baseURL: baseURL)

      if !vmDir.isExplicitlyPulled() && incRefCount == 0 {
        try FileManager.default.removeItem(at: baseURL)
      }
    }
  }

  func list() throws -> [(String, VMDirectory, Bool)] {
    var result: [(String, VMDirectory, Bool)] = Array()

    guard let enumerator = FileManager.default.enumerator(at: baseURL,
                                                          includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.producesRelativePathURLs]) else {
      return []
    }

    for case let foundURL as URL in enumerator {
      let vmDir = VMDirectory(baseURL: foundURL)

      if !vmDir.isCachedImage {
        continue
      }

      // Split the relative VM's path at the last component
      // and figure out which character should be used
      // to join them together, either ":" for tags or
      // "@" for hashes
      let parts = [foundURL.deletingLastPathComponent().relativePath, foundURL.lastPathComponent]
      var name: String

      let isSymlink = try foundURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink!
      if isSymlink {
        name = parts.joined(separator: ":")
      } else {
        name = parts.joined(separator: "@")
      }

      // Remove the percent-encoding, if any
      name = percentDecode(name)

      result.append((name, vmDir, isSymlink))
    }

    return result
  }

  func prunables() throws -> [Prunable] {
    try list().filter { (_, vmDir, isSymlink) in
      !isSymlink && vmDir.isStandalone
    }.map { (_, vmDir, _) in vmDir }
  }

  func pull(_ name: RemoteName, registry: Registry, concurrency: UInt, deduplicate: Bool) async throws {
    OpenTelemetry.instance.contextProvider.activeSpan?.setAttribute(
      key: "oci.image-name",
      value: .string(name.description)
    )

    defaultLogger.appendNewLine("pulling manifest...")

    let (manifest, manifestData) = try await registry.pullManifest(reference: name.reference.value)

    let digestName = RemoteName(host: name.host, namespace: name.namespace,
                                reference: Reference(digest: Digest.hash(manifestData)))

    if try hasCompleteLinkedImage(name, digestName: digestName, manifest: manifest) {
      // optimistically check if we need to do anything at all before locking
      defaultLogger.appendNewLine("\(digestName) image is already cached and linked!")
      return
    }

    // Ensure that host directory for given RemoteName exists in OCI storage
    let hostDirectoryURL = hostDirectoryURL(digestName)
    try FileManager.default.createDirectory(at: hostDirectoryURL, withIntermediateDirectories: true)

    // Acquire a lock on it to prevent concurrent pulls for a single host
    let lock = try FileLock(lockURL: hostDirectoryURL)

    let sucessfullyLocked = try lock.trylock()
    if !sucessfullyLocked {
      print("waiting for lock...")
      try lock.lock()
    }
    defer { try! lock.unlock() }

    if Task.isCancelled {
      throw CancellationError()
    }

    if try !hasCompleteCachedImage(digestName, manifest: manifest) {
      let span = OTel.shared.tracer.spanBuilder(spanName: "pull").setActive(true).startSpan()
      defer { span.end() }

      let tmpVMDir = try VMDirectory.temporaryDeterministic(key: name.description)
      let digestVMDir = VMDirectory(baseURL: vmURL(digestName))
      let preserveExplicitlyPulledMark = digestVMDir.isExplicitlyPulled()

      // Open an existing VM directory corresponding to this name, if any,
      // marking it as outdated to speed up the garbage collection process
      _ = try? open(name, Date(timeIntervalSince1970: 0))

      // Lock the temporary VM directory to prevent it's garbage collection
      let tmpVMDirLock = try FileLock(lockURL: tmpVMDir.baseURL)
      try tmpVMDirLock.lock()

      // A previously pulled standalone image already has the complete base
      // disk locally as disk.img. Promote that file into the content store
      // before sizing or pulling so a stacked child only fetches overlays.
      try reuseStandaloneDiskForStackedBaseIfPossible(manifest)

      // Try to reclaim some cache space if we know the VM size in advance
      if let requiredDiskStorageBytes = try requiredDiskStorageBytes(for: manifest) {
        if let telemetryValue = Int(exactly: requiredDiskStorageBytes) {
          OpenTelemetry.instance.contextProvider.activeSpan?.setAttribute(
            key: "oci.image-required-disk-storage-bytes",
            value: .int(telemetryValue)
          )
        }

        let otherVMFilesSize: UInt64 = 128 * 1024 * 1024
        let requiredStorage = requiredDiskStorageBytes.addingReportingOverflow(otherVMFilesSize)
        guard !requiredStorage.overflow else {
          throw RuntimeError.PullFailed("required pull storage size overflows UInt64")
        }

        try Prune.reclaimIfNeeded(requiredStorage.partialValue)
      }

      try await withTaskCancellationHandler(operation: {
        try await retry(maxAttempts: 5) {
          // Existing standalone images can still reuse another complete local disk.
          // Stacked images reconstruct their immutable files through the
          // shared content store instead of materializing disk.img.
          let localLayerCache: LocalLayerCache?
          switch try manifest.tartDiskRepresentation() {
          case .flat:
            localLayerCache = try await chooseLocalLayerCache(name, manifest, registry)
          case .stacked:
            localLayerCache = nil
          }

          if let llc = localLayerCache {
            let deduplicatedHuman = ByteCountFormatter.string(fromByteCount: Int64(llc.deduplicatedBytes), countStyle: .file)

            if deduplicate {
              defaultLogger.appendNewLine("found an image \(llc.name) that will allow us to deduplicate \(deduplicatedHuman), using it as a base...")
            } else {
              defaultLogger.appendNewLine("found an image \(llc.name) that will allow us to avoid fetching \(deduplicatedHuman), will try use it...")
            }
          }

          try await tmpVMDir.pullFromRegistry(registry: registry, manifest: manifest, concurrency: concurrency, localLayerCache: localLayerCache, deduplicate: deduplicate)
        } recoverFromFailure: { error in
          if error is URLError {
            print("Error pulling image: \"\(error.localizedDescription)\", attempting to re-try...")

            return .retry
          }

          return .throw
        }

        // Preserve the exact manifest bytes received from the registry. Its
        // digest identifies this cached image and stacked VMs pin it.
        try manifestData.write(to: tmpVMDir.manifestURL)
        if preserveExplicitlyPulledMark {
          tmpVMDir.markExplicitlyPulled()
        }

        try move(digestName, from: tmpVMDir)
      }, onCancel: {
        try? FileManager.default.removeItem(at: tmpVMDir.baseURL)
      })
    } else {
      defaultLogger.appendNewLine("\(digestName) image is already cached! creating a symlink...")
    }

    if name != digestName {
      // Create new or overwrite the old symbolic link
      try link(from: name, to: digestName)
    } else {
      // Ensure that images pulled by content digest
      // are excluded from garbage collection
      VMDirectory(baseURL: vmURL(name)).markExplicitlyPulled()
    }

    // to explicitly set the image as being accessed so it won't get pruned immediately
    _ = try VMStorageOCI().open(name)
  }

  /// Returns `nil` for standalone images and the missing immutable disk-file groups
  /// for stacked images. `ContentStore.existingContentURL()` intentionally
  /// validates the digest so corrupt entries are repaired by a normal pull.
  private func missingStackedDiskFileGroups(for manifest: OCIManifest) throws -> [TartDiskFileGroup]? {
    guard case .stacked(let base, let overlays) = try manifest.tartDiskRepresentation() else {
      return nil
    }

    let contentStore = try ContentStore()
    var missingGroups: [TartDiskFileGroup] = []
    for group in [base] + overlays {
      guard let contentDigest = group.contentDigest else {
        throw OCIManifestValidationError.invalidDiskMetadata("stacked disk files need a whole-file content digest")
      }
      if try contentStore.existingContentURL(for: contentDigest) == nil {
        missingGroups.append(group)
      }
    }

    return missingGroups
  }

  /// Seed a stacked image's immutable base from an already pulled standalone
  /// OCI record when both manifests describe the same transport chunks. The
  /// content store still verifies the whole-file digest before publishing it.
  func reuseStandaloneDiskForStackedBaseIfPossible(_ manifest: OCIManifest) throws {
    guard case .stacked(let base, _) = try manifest.tartDiskRepresentation(),
          let contentDigest = base.contentDigest else {
      return
    }

    let contentStore = try ContentStore()
    // Content-store entries are verified when installed. Avoid hashing a
    // potentially large prewarmed base again on every stacked pull.
    guard try contentStore.contentURLIfPresent(for: contentDigest) == nil else {
      return
    }

    for (_, vmDir, isSymlink) in try list() where !isSymlink && vmDir.isStandalone {
      guard let manifestData = try? Data(contentsOf: vmDir.manifestURL),
            let candidateManifest = try? OCIManifest(fromJSON: manifestData),
            case .flat(let candidateBase) = try? candidateManifest.tartDiskRepresentation(),
            diskChunksMatch(candidateBase.chunks, base.chunks) else {
        continue
      }

      let temporaryURL = try contentStore.temporaryContentURL(for: contentDigest)
      do {
        try FileManager.default.copyItem(at: vmDir.diskURL, to: temporaryURL)
        _ = try contentStore.install(temporaryURL, contentDigest: contentDigest)
        return
      } catch ContentStoreError.contentDigestMismatch {
        try? FileManager.default.removeItem(at: temporaryURL)
      } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        throw error
      }
    }
  }

  /// Compare the OCI transport identity while ignoring stacked-only
  /// whole-file annotations added to the first base chunk.
  private func diskChunksMatch(_ left: [OCIManifestLayer], _ right: [OCIManifestLayer]) -> Bool {
    guard left.count == right.count else {
      return false
    }

    return zip(left, right).allSatisfy { left, right in
      left.mediaType == right.mediaType &&
        left.size == right.size &&
        left.digest == right.digest &&
        left.uncompressedSize() == right.uncompressedSize() &&
        left.uncompressedContentDigest() == right.uncompressedContentDigest()
    }
  }

  func linked(from: RemoteName, to: RemoteName) -> Bool {
    do {
      let resolvedFrom = try FileManager.default.destinationOfSymbolicLink(atPath: vmURL(from).path)
      return resolvedFrom == vmURL(to).path
    } catch {
      return false
    }
  }

  func link(from: RemoteName, to: RemoteName) throws {
    try? FileManager.default.removeItem(at: vmURL(from))

    try FileManager.default.createSymbolicLink(at: vmURL(from), withDestinationURL: vmURL(to))

    try gc()
  }

  func chooseLocalLayerCache(_ name: RemoteName, _ manifest: OCIManifest, _ registry: Registry) async throws -> LocalLayerCache? {
    // Establish a closure that will calculate how much bytes
    // we'll deduplicate if we re-use the given manifest
    let target = Swift.Set(manifest.layers)

    let calculateDeduplicatedBytes = { (manifest: OCIManifest) -> UInt64 in
      target.intersection(manifest.layers).map({ UInt64($0.size) }).reduce(0, +)
    }

    // Load OCI VM images and their manifests (if present)
    var candidates: [(
      name: String,
      vmDir: VMDirectory,
      manifest: OCIManifest,
      manifestDigest: String,
      deduplicatedBytes: UInt64
    )] = []

    for (name, vmDir, isSymlink) in try list() {
      if isSymlink || !vmDir.isStandalone {
        continue
      }

      guard let manifestJSON = try? Data(contentsOf: vmDir.manifestURL) else {
        continue
      }

      guard let manifest = try? OCIManifest(fromJSON: manifestJSON) else {
        continue
      }

      candidates.append((
        name,
        vmDir,
        manifest,
        Digest.hash(manifestJSON),
        calculateDeduplicatedBytes(manifest)
      ))
    }

    // Previously we haven't stored the OCI VM image manifests, but still fetched the VM image manifest if
    // what the user was trying to pull was a tagged image, and we already had that image in the OCI VM cache
    //
    // Keep supporting this behavior for backwards comaptibility, but only communicate
    // with the registry if we haven't already retrieved the manifest for that OCI VM image.
    if name.reference.type == .Tag,
       let vmDir = try? open(name),
       vmDir.isStandalone,
       let digest = try? digest(name),
       !candidates.contains(where: { $0.manifestDigest == digest }),
       let (manifest, manifestData) = try? await registry.pullManifest(reference: digest) {
      candidates.append((
        name.description,
        vmDir,
        manifest,
        Digest.hash(manifestData),
        calculateDeduplicatedBytes(manifest)
      ))
    }

    // Now, find the best match based on how many bytes we'll deduplicate
    let choosen = candidates.filter {
      $0.deduplicatedBytes > 1024 * 1024 * 1024 // save at least 1GB
    }.max { left, right in
      return left.deduplicatedBytes < right.deduplicatedBytes
    }

    return try choosen.flatMap({ choosen in
      try LocalLayerCache(choosen.name, choosen.deduplicatedBytes, choosen.vmDir.diskURL, choosen.manifest)
    })
  }
}

extension URL {
  func appendingRemoteName(_ name: RemoteName) -> URL {
    var result: URL = self

    for pathComponent in (percentEncode(name.host) + "/" + name.namespace + "/" + name.reference.value).split(separator: "/") {
      result = result.appendingPathComponent(String(pathComponent))
    }

    return result
  }

  func appendingHost(_ name: RemoteName) -> URL {
    self.appendingPathComponent(percentEncode(name.host), isDirectory: true)
  }
}

// Work around a pretty inane Swift's URL behavior where calling
// appendingPathComponent() or deletingLastPathComponent() on a
// URL like URL(filePath: "example.com:8080") (note the "filePath")
// will flip its isFileURL from "true" to "false" and discard its
// absolute path infromation (if any).
//
// The same kind of operations won't do anything to a URL like
// URL(filePath: "127.0.0.1:8080"), which makes things even more
// ridiculous.
private func percentEncode(_ s: String) -> String {
  return s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: ":").inverted)!
}

private func percentDecode(_ s: String) -> String {
  s.removingPercentEncoding!
}

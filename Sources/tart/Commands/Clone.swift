import ArgumentParser
import Foundation
import SystemConfiguration

struct Clone: AsyncParsableCommand {
  static var configuration = CommandConfiguration(
    abstract: "Clone a VM",
    discussion: """
    Creates a local virtual machine by cloning either a remote or another local virtual machine.

    Due to copy-on-write magic in Apple File System, a cloned VM won't actually claim all the space right away.
    Only changes to a cloned disk will be written and claim new space. This also speeds up clones enormously.

    By default, Tart checks available capacity in Tart's home directory and tries to reclaim minimum possible storage for the cloned image
    to fit. This behaviour is called "automatic pruning" and can be disabled by setting TART_NO_AUTO_PRUNE environment variable.
    """
  )

  @Argument(help: "source VM name", completion: .custom(completeMachines))
  var sourceName: String

  @Argument(help: "new VM name")
  var newName: String

  @Flag(help: "connect to the OCI registry via insecure HTTP protocol")
  var insecure: Bool = false

  @Option(help: "network concurrency to use when pulling a remote VM from the OCI-compatible registry")
  var concurrency: UInt = 4

  @Flag(help: .hidden)
  var deduplicate: Bool = false

  @Flag(help: "create a stacked disk that uses the source image as an immutable base")
  var stacked: Bool = false

  @Option(help: ArgumentHelp("limit automatic pruning to n gigabytes", valueName: "n"))
  var pruneLimit: UInt = 100

  func validate() throws {
    if newName.contains("/") {
      throw ValidationError("<new-name> should be a local name")
    }

    if concurrency < 1 {
      throw ValidationError("network concurrency cannot be less than 1")
    }
  }

  func run() async throws {
    let ociStorage = try VMStorageOCI()
    let localStorage = try VMStorageLocal()
    let remoteName = try? RemoteName(sourceName)

    if stacked {
      guard remoteName != nil else {
        throw ValidationError("--stacked requires a remote image")
      }
      try DiskImageStack.requireSupport()
    }

    if let remoteName, try !ociStorage.hasUsableCachedImageForClone(remoteName, requireManifest: stacked) {
      // Pull the VM in case it's OCI-based and doesn't exist locally yet
      let registry = try Registry(host: remoteName.host, namespace: remoteName.namespace, insecure: insecure)
      var resolvedManifest: (manifest: OCIManifest, data: Data)?

      // Fail before pulling disk content when this host cannot create a writable stacked disk.
      if !stacked {
        let (manifest, manifestData) = try await registry.pullManifest(reference: remoteName.reference.value)
        if manifest.layers.contains(where: { $0.mediaType == asifOverlayMediaType }) {
          try DiskImageStack.requireSupport()
        }
        resolvedManifest = (manifest, manifestData)
      }

      try await ociStorage.pull(
        remoteName,
        registry: registry,
        concurrency: concurrency,
        deduplicate: deduplicate,
        requireManifest: stacked,
        resolvedManifest: resolvedManifest
      )
    }

    let sourceVM = try VMStorageHelper.open(sourceName)
    if sourceVM.isStackedVM || sourceVM.isStackedCachedImage {
      try DiskImageStack.requireSupport()
    }
    let tmpVMDir = try VMDirectory.temporary()

    // Lock the temporary VM directory to prevent it's garbage collection
    let tmpVMDirLock = try FileLock(lockURL: tmpVMDir.baseURL)
    try tmpVMDirLock.lock()

    try await withTaskCancellationHandler(operation: {
      // Acquire a global lock
      let lock = try FileLock(lockURL: Config().tartHomeDir)
      try lock.lock()

      let sourceState = try sourceVM.state()
      let generateMAC = try localStorage.hasVMsWithMACAddress(macAddress: sourceVM.macAddress())
        && sourceState != .Suspended

      if stacked {
        guard sourceVM.isStandalone else {
          throw ValidationError("--stacked cannot use an image that already has a stacked disk")
        }
        guard try VMConfig(fromURL: sourceVM.configURL).os == .darwin else {
          throw ValidationError("--stacked currently supports only macOS images")
        }
        try sourceVM.cloneAsStackedBase(to: tmpVMDir, generateMAC: generateMAC)
      } else if sourceVM.isStackedCachedImage {
        try sourceVM.cloneStacked(to: tmpVMDir, copyWritableOverlay: false, generateMAC: generateMAC)
      } else if sourceVM.isStackedVM {
        guard sourceState == .Stopped else {
          throw RuntimeError.VMConfigurationError("VM \"\(sourceName)\" must be stopped before cloning")
        }
        try sourceVM.cloneStacked(to: tmpVMDir, copyWritableOverlay: true, generateMAC: generateMAC)
      } else {
        try sourceVM.clone(to: tmpVMDir, generateMAC: generateMAC)
      }

      try localStorage.move(newName, from: tmpVMDir)

      try lock.unlock()

      // APFS is doing copy-on-write, so the above cloning operation (just copying files on disk)
      // is not actually claiming new space until the VM is started and it writes something to disk.
      //
      // So, once we clone the VM let's try to claim the rest of space for the VM to run without errors.
      if sourceVM.isStandalone {
        let unallocatedBytes = try sourceVM.sizeBytes() - sourceVM.allocatedSizeBytes()
        // Avoid reclaiming an excessive amount of disk space.
        let reclaimBytes = min(unallocatedBytes, Int(pruneLimit) * 1024 * 1024 * 1024)
        if reclaimBytes > 0 {
          try Prune.reclaimIfNeeded(UInt64(reclaimBytes), sourceVM)
        }
      } else if sourceVM.isStackedVM || sourceVM.isStackedCachedImage {
        let clonedVM = try localStorage.open(newName)
        // A stacked clone owns only its writable overlay locally, but that
        // overlay may grow to the full guest-visible disk block layout at
        // runtime. Reclaim against the clone so it is not pruned itself.
        let unallocatedBytes = try clonedVM.diskSizeBytes() - clonedVM.allocatedSizeBytes()
        let reclaimBytes = min(unallocatedBytes, Int(pruneLimit) * 1024 * 1024 * 1024)
        if reclaimBytes > 0 {
          try Prune.reclaimIfNeeded(UInt64(reclaimBytes), clonedVM)
        }
      }
    }, onCancel: {
      try? tmpVMDir.removeFromDisk()
    })
  }
}

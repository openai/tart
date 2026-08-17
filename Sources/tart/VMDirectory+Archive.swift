import Foundation
import System
import AppleArchive

fileprivate let permissions = FilePermissions(rawValue: 0o644)

// Compresses VMDirectory using Apple's proprietary archive format[1] and LZFSE compression,
// which is recommended on Apple platforms[2].
//
// [1]: https://developer.apple.com/documentation/accelerate/compressing_file_system_directories
// [2]: https://developer.apple.com/documentation/compression/algorithm/lzfse
extension VMDirectory {
  func exportToArchive(path: String) throws {
    let temporaryArchive = try stackedArchiveDirectoryIfNeeded()
    let archiveSourceURL = temporaryArchive?.vmDirectory.baseURL ?? baseURL

    defer {
      if let temporaryArchive {
        try? temporaryArchive.lock.unlock()
        try? temporaryArchive.vmDirectory.removeFromDisk()
      }
    }

    guard let fileStream = ArchiveByteStream.fileStream(
      path: FilePath(path),
      mode: .writeOnly,
      options: [.create, .truncate],
      permissions: permissions
    ) else {
      let details = Errno(rawValue: CInt(errno))

      throw RuntimeError.ExportFailed("ArchiveByteStream.fileStream() failed: \(details)")
    }
    defer {
      try? fileStream.close()
    }

    guard let compressionStream = ArchiveByteStream.compressionStream(
      using: .lzfse,
      writingTo: fileStream
    ) else {
      let details = Errno(rawValue: CInt(errno))

      throw RuntimeError.ExportFailed("ArchiveByteStream.compressionStream() failed: \(details)")
    }
    defer {
      try? compressionStream.close()
    }

    guard let encodeStream = ArchiveStream.encodeStream(writingTo: compressionStream) else {
      let details = Errno(rawValue: CInt(errno))

      throw RuntimeError.ExportFailed("ArchiveStream.encodeStream() failed: \(details)")
    }
    defer {
      try? encodeStream.close()
    }

    guard let keySet = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM") else {
      return
    }

    try encodeStream.writeDirectoryContents(archiveFrom: FilePath(archiveSourceURL.path), keySet: keySet)
  }

  func importFromArchive(path: String) throws {
    guard let fileStream = ArchiveByteStream.fileStream(path: FilePath(path), mode: .readOnly, options: [],
                                                        permissions: permissions) else {
      let details = Errno(rawValue: CInt(errno))

      throw RuntimeError.ImportFailed("ArchiveByteStream.fileStream() failed: \(details)")
    }
    defer {
      try? fileStream.close()
    }

    guard let decompressionStream = ArchiveByteStream.decompressionStream(readingFrom: fileStream) else {
      let details = Errno(rawValue: CInt(errno))

      throw RuntimeError.ImportFailed("ArchiveByteStream.decompressionStream() failed: \(details)")
    }
    defer {
      try? decompressionStream.close()
    }

    guard let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressionStream) else {
      let details = Errno(rawValue: CInt(errno))

      throw RuntimeError.ImportFailed("ArchiveStream.decodeStream() failed: \(details)")
    }
    defer {
      try? decodeStream.close()
    }

    guard let extractStream = ArchiveStream.extractStream(extractingTo: FilePath(baseURL.path),
                                                          flags: [.ignoreOperationNotPermitted]) else {
      let details = Errno(rawValue: CInt(errno))

      throw RuntimeError.ImportFailed("ArchiveStream.extractStream() failed: \(details)")
    }
    defer {
      try? extractStream.close()
    }

    _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)

    if isStackedVM {
      try restoreStackedArchive()
    }
  }

  /// Builds a self-contained staging directory for a stacked archive, if this
  /// directory currently resolves to a stacked VM or cached image.
  private func stackedArchiveDirectoryIfNeeded() throws -> (vmDirectory: VMDirectory, lock: FileLock)? {
    guard isStackedVM || isStackedCachedImage else {
      return nil
    }
    try DiskImageStack.requireSupport()

    let contentStore = try ContentStore()
    let archiveVMDir = try VMDirectory.temporary()
    let archiveVMDirLock = try FileLock(lockURL: archiveVMDir.baseURL)
    try archiveVMDirLock.lock()

    do {
      let stagedSource: (isStackedVM: Bool, contentDigests: [String])? = try contentStore.withPruneLock {
        () -> (isStackedVM: Bool, contentDigests: [String])? in
        // OCI tags are mutable symlinks. Resolve one digest record while tag
        // replacement and cached-image deletion are blocked, then copy every
        // source-owned file before releasing the lock.
        let sourceVMDir = VMDirectory(baseURL: baseURL.resolvingSymlinksInPath())
        guard sourceVMDir.isStackedVM || sourceVMDir.isStackedCachedImage else {
          throw RuntimeError.ExportFailed("VM changed while preparing export, retry the command")
        }

        let sourceIsStackedVM = sourceVMDir.isStackedVM
        let sourceVMLock: PIDLock?
        if sourceIsStackedVM {
          let lock = try sourceVMDir.lock()
          guard try lock.trylock() else {
            throw RuntimeError.ExportFailed("VM \"\(sourceVMDir.name)\" must be stopped before export")
          }
          sourceVMLock = lock

          // Holding the PID lock proves that the VM is not running. A saved
          // state file is the remaining suspended state that must reject export.
          guard !FileManager.default.fileExists(atPath: sourceVMDir.stateURL.path) else {
            try? lock.unlock()
            throw RuntimeError.ExportFailed("VM \"\(sourceVMDir.name)\" must be stopped before export")
          }
        } else {
          sourceVMLock = nil
        }
        defer { try? sourceVMLock?.unlock() }

        try FileManager.default.copyItem(at: sourceVMDir.configURL, to: archiveVMDir.configURL)
        try FileManager.default.copyItem(at: sourceVMDir.nvramURL, to: archiveVMDir.nvramURL)
        try FileManager.default.copyItem(at: sourceVMDir.manifestURL, to: archiveVMDir.manifestURL)
        if sourceIsStackedVM {
          try FileManager.default.copyItem(at: sourceVMDir.overlayURL, to: archiveVMDir.overlayURL)
        }

        return (sourceIsStackedVM, try archiveVMDir.diskContentDigests())
      }

      guard let stagedSource else {
        try archiveVMDirLock.unlock()
        try archiveVMDir.removeFromDisk()
        return nil
      }

      if !stagedSource.isStackedVM {
        try archiveVMDir.diskImageStack().createWritableOverlay()
      }

      // The staged manifest is now an in-progress reference, so immutable
      // content remains protected while these potentially large copies run
      // without holding the global prune lock.
      for contentDigest in stagedSource.contentDigests {
        guard let sourceURL = try contentStore.existingContentURL(for: contentDigest) else {
          throw RuntimeError.ExportFailed("VM is missing cached disk content \(contentDigest)")
        }

        let destinationURL = try contentStore.contentURL(
          for: contentDigest,
          under: archiveContentStoreURL(in: archiveVMDir)
        )
        try FileManager.default.createDirectory(
          at: destinationURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
      }

      return (archiveVMDir, archiveVMDirLock)
    } catch {
      try? archiveVMDirLock.unlock()
      try? archiveVMDir.removeFromDisk()
      throw error
    }
  }

  /// Restores immutable files from an archive into the shared content store,
  /// removes the archive-only payload, then validates the resulting stack.
  private func restoreStackedArchive() throws {
    try DiskImageStack.requireSupport()

    let contentStore = try ContentStore()
    // The extracted manifest is already a reference; synchronize publication
    // with a concurrent prune before installing its immutable content.
    try contentStore.synchronizePublishedReferences()
    for contentDigest in try diskContentDigests() {
      if try contentStore.existingContentURL(for: contentDigest) != nil {
        continue
      }

      let archivedContentURL = try contentStore.contentURL(
        for: contentDigest,
        under: archiveContentStoreURL(in: self)
      )
      guard FileManager.default.fileExists(atPath: archivedContentURL.path) else {
        throw RuntimeError.ImportFailed("archive is missing disk content \(contentDigest)")
      }

      let temporaryURL = try contentStore.temporaryContentURL(for: contentDigest)
      do {
        try FileManager.default.copyItem(at: archivedContentURL, to: temporaryURL)
        _ = try contentStore.install(temporaryURL, contentDigest: contentDigest)
      } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        throw error
      }
    }

    try FileManager.default.removeItem(at: archiveContentStoreURL(in: self))
    try? FileManager.default.removeItem(at: stateURL)

    // Opening the attachment validates the reconstructed immutable stack and
    // imported writable overlay before the VM enters local storage.
    _ = try diskImageStack().makeAttachment()
  }

  private func archiveContentStoreURL(in vmDir: VMDirectory) -> URL {
    vmDir.baseURL.appendingPathComponent("content", isDirectory: true)
  }

}

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
    guard !isStackedVM && !isStackedCachedImage else {
      throw RuntimeError.ExportFailed("exporting stacked VMs is not supported yet")
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

    try encodeStream.writeDirectoryContents(archiveFrom: FilePath(baseURL.path), keySet: keySet)
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
  }
}

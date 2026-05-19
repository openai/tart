import Foundation

/// Chunked file/▸directory copy with throttled progress callbacks and
/// cancellation. Used by the drag-and-drop handler to feed `DropProgressToast`
/// without freezing the VM render view.
///
/// - `copyTree` handles both regular files and directories (folders, `.app`
///   bundles, packages) — directories are walked depth-first and every
///   regular file inside is streamed through the same chunked path.
/// - Any pre-existing item at `dst` is removed first (drops semantically
///   replace).
/// - Polls `token.isCancelled` between chunks; throws `DropCopyCancelled`
///   immediately on cancel.
/// - `progress(copiedSoFar)` is reported at most once every ~50 ms (cumulative
///   across the whole tree), plus a guaranteed final call so the bar always
///   reaches 100%.
/// - On any throw (I/O error or cancellation) the partial output at `dst` is
///   removed so a truncated file never becomes visible to the guest.
enum DropProgressCopier {
  private static let walkKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
  private static let walkKeySet: Swift.Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]

  /// Total byte size of `url`: the file size for a regular file, or the
  /// recursive sum of regular-file sizes for a directory. Best-effort —
  /// unreadable entries contribute 0 (the bar just runs a touch fast).
  static func totalSize(of url: URL) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

    if !isDir.boolValue {
      return ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
    }

    var total: Int64 = 0
    if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
      for case let child as URL in en {
        let v = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
      }
    }
    return total
  }

  /// Copy `src` (file or directory) to `dst`. On any error the partial `dst`
  /// is cleaned up before rethrowing, so callers never leave a half-written
  /// item in the drop zone.
  static func copyTree(
    from src: URL,
    to dst: URL,
    totalBytes: Int64,
    token: DropCancellationToken,
    progress: (Int64) -> Void
  ) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: dst.path) {
      try fm.removeItem(at: dst)
    }

    var copied: Int64 = 0
    var lastReport = Date(timeIntervalSince1970: 0)
    let reportInterval: TimeInterval = 0.05

    func report(force: Bool) {
      let now = Date()
      if force || now.timeIntervalSince(lastReport) >= reportInterval {
        progress(copied)
        lastReport = now
      }
    }

    do {
      var isDir: ObjCBool = false
      _ = fm.fileExists(atPath: src.path, isDirectory: &isDir)

      if isDir.boolValue {
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        // Deterministic depth-first walk so the destination tree mirrors the
        // source and directories are created before their contents.
        let children = (try? fm.contentsOfDirectory(
          at: src, includingPropertiesForKeys: walkKeys, options: []
        )) ?? []
        for child in children.sorted(by: { $0.path < $1.path }) {
          if token.isCancelled { throw DropCopyCancelled() }
          let childDst = dst.appendingPathComponent(child.lastPathComponent)
          try copyInto(child, childDst, &copied, token, report)
        }
      } else {
        try copyFile(src, dst, &copied, token, report)
      }

      report(force: true)
    } catch {
      try? fm.removeItem(at: dst)
      throw error
    }
  }

  // MARK: - Internals

  private static func copyInto(
    _ src: URL,
    _ dst: URL,
    _ copied: inout Int64,
    _ token: DropCancellationToken,
    _ report: (Bool) -> Void
  ) throws {
    let fm = FileManager.default
    let values = try? src.resourceValues(forKeys: walkKeySet)
    if values?.isDirectory == true {
      try fm.createDirectory(at: dst, withIntermediateDirectories: true)
      let children = (try? fm.contentsOfDirectory(
        at: src, includingPropertiesForKeys: walkKeys, options: []
      )) ?? []
      for child in children.sorted(by: { $0.path < $1.path }) {
        if token.isCancelled { throw DropCopyCancelled() }
        try copyInto(child, dst.appendingPathComponent(child.lastPathComponent), &copied, token, report)
      }
    } else if values?.isRegularFile == true {
      try copyFile(src, dst, &copied, token, report)
    } else {
      // Symlink / socket / device node: recreate symlinks, skip the rest
      // rather than block on a fifo or copy a device.
      if let dest = try? fm.destinationOfSymbolicLink(atPath: src.path) {
        try? fm.createSymbolicLink(atPath: dst.path, withDestinationPath: dest)
      }
    }
  }

  private static func copyFile(
    _ src: URL,
    _ dst: URL,
    _ copied: inout Int64,
    _ token: DropCancellationToken,
    _ report: (Bool) -> Void
  ) throws {
    let fm = FileManager.default
    guard fm.createFile(atPath: dst.path, contents: nil) else {
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(EIO),
        userInfo: [NSLocalizedDescriptionKey: "Could not create destination file \(dst.path)"]
      )
    }

    let input = try FileHandle(forReadingFrom: src)
    let output = try FileHandle(forWritingTo: dst)
    defer {
      try? input.close()
      try? output.close()
    }

    let chunkSize = 1 * 1024 * 1024  // 1 MiB — amortizes syscalls, still
    // streams progress and bounds cancellation latency on fast disks.
    while true {
      if token.isCancelled { throw DropCopyCancelled() }
      let chunk = input.readData(ofLength: chunkSize)
      if chunk.isEmpty { break }
      try output.write(contentsOf: chunk)
      copied += Int64(chunk.count)
      report(false)
    }
  }
}

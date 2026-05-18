import Foundation

/// Chunked file copy with throttled progress callbacks and cancellation.
/// Used by the drag-and-drop handler to feed `DropProgressToast` without
/// freezing the VM render view.
///
/// - Removes any existing file at `dst` first (drops semantically replace).
/// - Polls `token.isCancelled` between chunks; throws `DropCopyCancelled`
///   immediately on cancel so the caller can clean up the partial file.
/// - Reports `progress(copied)` at most once every ~50 ms during the copy,
///   plus a final call at completion so the bar always reaches 100%.
/// - Throws on either side's I/O error; partial output at `dst` is left in
///   place so the caller can decide how to surface the error (delete +
///   alert, or leave it for the user).
enum DropProgressCopier {
  static func copy(
    from src: URL,
    to dst: URL,
    totalBytes: Int64,
    token: DropCancellationToken,
    progress: (Int64) -> Void
  ) throws {
    _ = totalBytes  // accepted for future use (ETA, average rate, etc.)

    if FileManager.default.fileExists(atPath: dst.path) {
      try FileManager.default.removeItem(at: dst)
    }
    guard FileManager.default.createFile(atPath: dst.path, contents: nil) else {
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
    let reportInterval: TimeInterval = 0.05
    var lastReport = Date(timeIntervalSince1970: 0)
    var copied: Int64 = 0

    while true {
      if token.isCancelled { throw DropCopyCancelled() }

      let chunk = input.readData(ofLength: chunkSize)
      if chunk.isEmpty { break }
      try output.write(contentsOf: chunk)
      copied += Int64(chunk.count)

      let now = Date()
      if now.timeIntervalSince(lastReport) >= reportInterval {
        progress(copied)
        lastReport = now
      }
    }
    // Always fire a final callback so the UI reaches 100% even when the
    // file finished inside the throttle window.
    progress(copied)
  }
}

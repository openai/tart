import Foundation

/// Thread-safe cancellation flag for an in-flight host→guest copy. The toast
/// holds one of these and flips it when the user clicks the close button;
/// `DropProgressCopier` polls it between chunks and throws `DropCopyCancelled`.
final class DropCancellationToken {
  private let lock = NSLock()
  private var _cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _cancelled
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    _cancelled = true
  }
}

/// Sentinel thrown by `DropProgressCopier.copy` when the caller's token is
/// flipped mid-copy. Distinct from a real I/O failure so the drop handler can
/// suppress the "Failed to copy" alert in this case.
struct DropCopyCancelled: Error {}

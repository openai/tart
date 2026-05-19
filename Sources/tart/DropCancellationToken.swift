import Foundation

/// Thread-safe cancellation flag for an in-flight host→guest copy. The toast
/// holds one of these and flips it when the user clicks the close button;
/// `DropProgressCopier` polls it between chunks and throws `DropCopyCancelled`.
///
/// `onCancel` lets callers react to cancellation imperatively — used by the
/// file-promise path, whose `receivePromisedFiles` API has no cancellation
/// parameter, to tear down its operation queue and unblock its wait loop.
final class DropCancellationToken {
  private let lock = NSLock()
  private var _cancelled = false
  private var handlers: [() -> Void] = []

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _cancelled
  }

  func cancel() {
    lock.lock()
    if _cancelled {
      lock.unlock()
      return
    }
    _cancelled = true
    let toRun = handlers
    handlers = []
    lock.unlock()
    toRun.forEach { $0() }
  }

  /// Invoke `handler` as soon as the token is cancelled — immediately if it
  /// already is. Handlers run once, outside the lock.
  func onCancel(_ handler: @escaping () -> Void) {
    lock.lock()
    if _cancelled {
      lock.unlock()
      handler()
      return
    }
    handlers.append(handler)
    lock.unlock()
  }
}

/// Sentinel thrown by `DropProgressCopier.copy` when the caller's token is
/// flipped mid-copy. Distinct from a real I/O failure so the drop handler can
/// suppress the "Failed to copy" alert in this case.
struct DropCopyCancelled: Error {}

import AppKit
import Foundation

/// Monotonic per-file id. Stamped onto every `DropProgressToast` call so a
/// slow guest-relocation result for an earlier file can't clobber/hide the
/// toast while a later file in the same drop is still copying.
enum DropSession {
  private static let lock = NSLock()
  private static var counter = 0

  static func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    counter += 1
    return counter
  }
}

/// Tracks in-flight guest relocations process-wide so `tart run` can wait for
/// them before deleting the drop zone / calling `Foundation.exit`. Without
/// this, closing the VM window right after a drop races the guest `mv`
/// against drop-zone teardown and the file is lost.
final class RelocationGate {
  static let shared = RelocationGate()
  private let group = DispatchGroup()

  private init() {}

  func enter() { group.enter() }
  func leave() { group.leave() }

  /// Wait up to `timeout` seconds for outstanding relocations. Bridged off
  /// the caller's actor so it never blocks the main thread.
  func drain(timeout: TimeInterval) async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().async {
        _ = self.group.wait(timeout: .now() + timeout)
        cont.resume()
      }
    }
  }
}

/// No promised file could be received (every provider errored or timed out).
struct DropPromiseFailed: LocalizedError {
  var errorDescription: String? { "the source app didn't provide the file" }
}

/// Owns one VM window's drag-and-drop pipeline: brings dragged files (and
/// folders/.app bundles, and file promises) into a per-item subdirectory of
/// the shared drop zone, drives the progress toast, then asks the guest agent
/// to relocate them under the cursor.
///
/// Design notes addressing prior edge cases:
/// - Each item gets its own `dropRoot/<uuid>/` subdir, so same-named files in
///   one gesture (or rapid re-drops) never collide on the share path.
/// - Plain file/dir drags stream through `DropProgressCopier.copyTree`, which
///   handles directories and removes partial output on any failure, so a
///   half-written item is never visible to the guest.
/// - File promises are received *directly into* their subdir, so they are
///   written once by the source app — no host-side staging-then-copy.
/// - Relocations run one-at-a-time on a serial queue and register with
///   `RelocationGate`, bounding guest RPC/TCC pressure and making teardown
///   safe.
/// - Per-file `sessionID` keeps multi-file toasts from racing.
/// - On non-macOS guests (or when the control socket is unavailable) the
///   relocation step is skipped and the toast says so honestly.
final class DropHandler {
  private enum Item {
    case file(URL)
    case promise(NSFilePromiseReceiver)
  }

  private let dropRoot: URL
  private let controlSocketURL: URL?
  private let isMacGuest: Bool
  private let copyQueue = DispatchQueue(label: "org.cirruslabs.tart.dragdrop-copy", qos: .userInitiated)
  private let relocationQueue = DispatchQueue(label: "org.cirruslabs.tart.dragdrop-relocate")

  private var relocationPossible: Bool { isMacGuest && controlSocketURL != nil }

  init(dropRoot: URL, controlSocketURL: URL?, isMacGuest: Bool) {
    self.dropRoot = dropRoot
    self.controlSocketURL = controlSocketURL
    self.isMacGuest = isMacGuest
  }

  /// Entry point, called on the main thread from `performDragOperation`.
  /// `parentWindow` is only ever touched on the main thread again.
  func handle(
    fileURLs: [URL],
    promiseReceivers: [NSFilePromiseReceiver],
    normalizedPoint: CGPoint,
    parentWindow: NSWindow?
  ) {
    let cancelToken = DropCancellationToken()
    let box = WindowBox(parentWindow)
    let items: [Item] = fileURLs.map(Item.file) + promiseReceivers.map(Item.promise)
    guard !items.isEmpty else { return }

    copyQueue.async { [self] in
      var failures: [String] = []
      let total = items.count

      for (idx, item) in items.enumerated() {
        if cancelToken.isCancelled { break }

        let sessionID = DropSession.next()
        let subdir = dropRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Display name is known up front for both kinds; a promise provider
        // may de-duplicate on write, so relocation uses the *actual* names.
        let displayName: String
        switch item {
        case .file(let src): displayName = src.lastPathComponent
        case .promise(let r): displayName = r.fileNames.first ?? "Dropped file"
        }

        do {
          try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

          let writtenNames: [String]
          switch item {
          case .file(let src):
            let dest = subdir.appendingPathComponent(displayName)
            let totalBytes = DropProgressCopier.totalSize(of: src)
            DispatchQueue.main.async {
              DropProgressToast.shared.begin(
                parent: box.window, filename: displayName, totalBytes: totalBytes,
                index: idx + 1, count: total, cancelToken: cancelToken, sessionID: sessionID
              )
            }
            try DropProgressCopier.copyTree(
              from: src, to: dest, totalBytes: totalBytes, token: cancelToken
            ) { copied in
              DispatchQueue.main.async {
                DropProgressToast.shared.update(
                  copied: copied, total: totalBytes,
                  index: idx + 1, count: total, sessionID: sessionID
                )
              }
            }
            writtenNames = [displayName]

          case .promise(let receiver):
            // Promises carry no byte progress; totalBytes 0 → indeterminate
            // bar while the source app writes straight into the share.
            DispatchQueue.main.async {
              DropProgressToast.shared.begin(
                parent: box.window, filename: displayName, totalBytes: 0,
                index: idx + 1, count: total, cancelToken: cancelToken, sessionID: sessionID
              )
            }
            writtenNames = try receivePromise(receiver, into: subdir, token: cancelToken)
              .map { $0.lastPathComponent }
          }

          let waiting = relocationPossible
          DispatchQueue.main.async {
            DropProgressToast.shared.finish(
              success: true,
              destinationFolder: waiting ? nil : "the shared folder",
              awaitingRelocation: waiting,
              sessionID: sessionID
            )
          }
          for name in writtenNames {
            relocate(subdir: subdir, fileName: name, normalizedPoint: normalizedPoint, sessionID: sessionID)
          }
        } catch is DropCopyCancelled {
          try? FileManager.default.removeItem(at: subdir)
          DispatchQueue.main.async {
            DropProgressToast.shared.finish(success: false, cancelled: true, sessionID: sessionID)
          }
          break
        } catch {
          // copyTree already removed any partial output; drop the subdir too
          // and remember the failure for one combined alert.
          try? FileManager.default.removeItem(at: subdir)
          failures.append("\(displayName): \(error.localizedDescription)")
          DispatchQueue.main.async {
            DropProgressToast.shared.finish(success: false, sessionID: sessionID)
          }
        }
      }

      if !failures.isEmpty {
        let summary = failures
        DispatchQueue.main.async {
          let alert = NSAlert()
          alert.messageText = summary.count == 1
            ? "Failed to copy a file to the VM"
            : "Failed to copy \(summary.count) files to the VM"
          alert.informativeText = summary.joined(separator: "\n")
          alert.alertStyle = .warning
          alert.runModal()
        }
      }
    }
  }

  // MARK: - Relocation (serialized, one at a time)

  private func relocate(subdir: URL, fileName: String, normalizedPoint: CGPoint, sessionID: Int) {
    guard relocationPossible, let socket = controlSocketURL else {
      // Linux / no agent: the file stays in the shared folder. The toast
      // already said "Copied to the shared folder"; nothing more to do.
      return
    }

    RelocationGate.shared.enter()
    relocationQueue.async {
      defer { RelocationGate.shared.leave() }

      let guestPath = "/Volumes/My Shared Files/Dropped Files/"
        + subdir.lastPathComponent + "/" + fileName
      let sem = DispatchSemaphore(value: 0)
      var folder = "Shared Files"
      var moved = false

      Task {
        do {
          let outcome = try await GuestDropSynthesis.perform(
            controlSocketURL: socket,
            guestFilePath: guestPath,
            normalizedDropPoint: normalizedPoint
          )
          folder = outcome.destinationFolderName
          moved = true
        } catch {
          NSLog("[GuestDrop] relocate failed for \(guestPath): \(error)")
        }
        sem.signal()
      }
      sem.wait()

      // A successful relocation `mv`s the file out of the share (a cross-FS
      // move that unlinks the host-side source). Reap the subdir only once
      // it's empty, so a multi-file promise sharing one subdir isn't deleted
      // out from under its still-pending siblings. On failure the file stays
      // put for the user to find.
      if moved {
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: subdir.path)) ?? []
        if remaining.isEmpty {
          try? FileManager.default.removeItem(at: subdir)
        }
      }
      let resolved = folder
      DispatchQueue.main.async {
        DropProgressToast.shared.setFinalDestination(resolved, sessionID: sessionID)
      }
    }
  }

  // MARK: - File promises (drags from Photos, Mail, browsers, …)

  /// Receives `receiver`'s promised files *directly into* `subdir` (which is
  /// already the shared drop-zone location), so the source app writes them
  /// exactly once — no host-side staging-then-copy. Returns the URLs actually
  /// written. Throws `DropCopyCancelled` if the user cancelled, or
  /// `DropPromiseFailed` if the provider produced nothing.
  private func receivePromise(
    _ receiver: NSFilePromiseReceiver,
    into subdir: URL,
    token: DropCancellationToken
  ) throws -> [URL] {
    let opQueue = OperationQueue()
    let lock = NSLock()
    var urls: [URL] = []
    var firstError: Error?
    let sem = DispatchSemaphore(value: 0)
    let expected = max(1, receiver.fileNames.count)

    receiver.receivePromisedFiles(atDestination: subdir, options: [:], operationQueue: opQueue) { url, error in
      lock.lock()
      if let error = error {
        if firstError == nil { firstError = error }
      } else {
        urls.append(url)
      }
      lock.unlock()
      sem.signal()
    }

    // 30 s headroom per file for first-run providers (e.g. Photos exporting
    // originals) while still failing fast if a provider never calls back.
    for _ in 0..<expected {
      if token.isCancelled { throw DropCopyCancelled() }
      if sem.wait(timeout: .now() + 30) == .timedOut { break }
    }

    lock.lock()
    defer { lock.unlock() }
    if urls.isEmpty { throw firstError ?? DropPromiseFailed() }
    return urls
  }
}

/// Carries an `NSWindow` (main-thread-only) through the background copy
/// closure. It is only ever read back on the main thread.
private final class WindowBox: @unchecked Sendable {
  let window: NSWindow?
  init(_ window: NSWindow?) { self.window = window }
}

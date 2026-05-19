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

/// Owns one VM window's drag-and-drop pipeline: copies dragged files (and
/// file promises, and folders/.app bundles) into a per-file subdirectory of
/// the shared drop zone, drives the progress toast, then asks the guest agent
/// to relocate each file under the cursor.
///
/// Design notes addressing prior edge cases:
/// - Each file gets its own `dropRoot/<uuid>/` subdir, so same-named files in
///   one gesture (or rapid re-drops) never collide on the share path.
/// - `DropProgressCopier.copyTree` handles directories and removes partial
///   output on any failure, so a half-written item is never visible to guest.
/// - Relocations run one-at-a-time on a serial queue and register with
///   `RelocationGate`, bounding guest RPC/TCC pressure and making teardown
///   safe.
/// - Per-file `sessionID` keeps multi-file toasts from racing.
/// - On non-macOS guests (or when the control socket is unavailable) the
///   relocation step is skipped and the toast says so honestly.
final class DropHandler {
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

    copyQueue.async { [self] in
      var sources = fileURLs
      sources.append(contentsOf: resolvePromisedFiles(promiseReceivers, token: cancelToken))
      guard !sources.isEmpty else { return }

      var failures: [String] = []
      let total = sources.count

      for (idx, src) in sources.enumerated() {
        if cancelToken.isCancelled { break }

        let sessionID = DropSession.next()
        let name = src.lastPathComponent
        let subdir = dropRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dest = subdir.appendingPathComponent(name)
        let totalBytes = DropProgressCopier.totalSize(of: src)

        DispatchQueue.main.async {
          DropProgressToast.shared.begin(
            parent: box.window, filename: name, totalBytes: totalBytes,
            index: idx + 1, count: total, cancelToken: cancelToken, sessionID: sessionID
          )
        }

        do {
          try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
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

          let waiting = relocationPossible
          DispatchQueue.main.async {
            DropProgressToast.shared.finish(
              success: true,
              destinationFolder: waiting ? nil : "the shared folder",
              awaitingRelocation: waiting,
              sessionID: sessionID
            )
          }
          relocate(subdir: subdir, fileName: name, normalizedPoint: normalizedPoint, sessionID: sessionID)
        } catch is DropCopyCancelled {
          try? FileManager.default.removeItem(at: subdir)
          DispatchQueue.main.async {
            DropProgressToast.shared.finish(success: false, cancelled: true, sessionID: sessionID)
          }
          break
        } catch {
          // copyTree already removed the partial output; drop the now-empty
          // subdir too and remember the failure for one combined alert.
          try? FileManager.default.removeItem(at: subdir)
          failures.append("\(name): \(error.localizedDescription)")
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

      // Successful relocation `mv`s the file out of the share (a cross-FS
      // move that unlinks the host-side source), leaving an empty subdir to
      // reap. On failure the file stays put for the user to find.
      if moved {
        try? FileManager.default.removeItem(at: subdir)
      }
      let resolved = folder
      DispatchQueue.main.async {
        DropProgressToast.shared.setFinalDestination(resolved, sessionID: sessionID)
      }
    }
  }

  // MARK: - File promises (drags from Photos, Mail, browsers, …)

  /// Materializes `NSFilePromiseReceiver`s into a host-private staging dir and
  /// returns the written file URLs so they flow through the same copy path as
  /// plain file drags. Best-effort: anything that errors or times out is
  /// skipped (the drop just yields fewer files, never a crash).
  private func resolvePromisedFiles(
    _ receivers: [NSFilePromiseReceiver],
    token: DropCancellationToken
  ) -> [URL] {
    guard !receivers.isEmpty else { return [] }

    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("tart-drop-promise-\(UUID().uuidString)", isDirectory: true)
    guard (try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)) != nil else {
      return []
    }

    let opQueue = OperationQueue()
    let lock = NSLock()
    var urls: [URL] = []
    let sem = DispatchSemaphore(value: 0)
    let expected = receivers.reduce(0) { $0 + max(1, $1.fileNames.count) }

    for receiver in receivers {
      receiver.receivePromisedFiles(atDestination: staging, options: [:], operationQueue: opQueue) { url, error in
        if error == nil {
          lock.lock()
          urls.append(url)
          lock.unlock()
        }
        sem.signal()
      }
    }

    // 30 s headroom for first-run providers (e.g. Photos exporting originals)
    // while still failing fast if a provider never calls back.
    for _ in 0..<expected {
      if token.isCancelled { break }
      if sem.wait(timeout: .now() + 30) == .timedOut { break }
    }

    lock.lock()
    defer { lock.unlock() }
    return urls
  }
}

/// Carries an `NSWindow` (main-thread-only) through the background copy
/// closure. It is only ever read back on the main thread.
private final class WindowBox: @unchecked Sendable {
  let window: NSWindow?
  init(_ window: NSWindow?) { self.window = window }
}

import AppKit
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

/// Borderless HUD-style panel shown over the VM window during a host→guest
/// drag-and-drop copy. Renders like a macOS notification banner: anchored to
/// the top-right of the VM window, slides in from the right edge, shows the
/// filename / determinate bar / "[i/N] copied / total" detail line, and has
/// a close (⊗) button that cancels the in-flight copy.
///
/// All methods MUST be called on the main thread. Callers driving copies
/// from a background queue should hop via `DispatchQueue.main.async` first.
///
/// Lifecycle per file:
///   begin(...)                  -> panel appears (or retargets) and slides
///                                  in if it wasn't already visible
///   update(...)                 -> bar advances; no-op if not visible
///   finish(success:cancelled:)  -> brief "Done"/"Cancelled"/"Copy failed"
///                                  state, then auto-hide after ~0.8 s
///
/// Multiple files dropped in one gesture serially reuse the same panel and
/// increment the [i/N] counter without re-animating.
final class DropProgressToast {
  static let shared = DropProgressToast()

  private var panel: NSPanel?
  private var progressBar: NSProgressIndicator!
  private var titleLabel: NSTextField!
  private var detailLabel: NSTextField!
  private var cancelButton: NSButton!
  private var hideWorkItem: DispatchWorkItem?
  private weak var anchorWindow: NSWindow?

  /// Cancellation token for the copy currently driving the toast. Cleared
  /// once the user clicks ⊗ or `finish` is called, so a late click after the
  /// copy already completed does nothing.
  private var currentToken: DropCancellationToken?

  private init() {}

  /// Show the toast (or retarget it to a new file) and reset the progress
  /// bar. `parent` is the VM window; the panel becomes a child of it so it
  /// tracks movement and z-order. `cancelToken` is what the close button
  /// flips on click. `totalBytes <= 0` switches the bar to indeterminate.
  func begin(
    parent: NSWindow?,
    filename: String,
    totalBytes: Int64,
    index: Int,
    count: Int,
    cancelToken: DropCancellationToken
  ) {
    ensurePanel()
    hideWorkItem?.cancel()
    hideWorkItem = nil

    let wasAlreadyVisible = (panel?.isVisible == true)

    anchorWindow = parent
    currentToken = cancelToken

    titleLabel.stringValue = filename
    detailLabel.stringValue = formatDetail(copied: 0, total: totalBytes, index: index, count: count)
    cancelButton.isHidden = false
    cancelButton.isEnabled = true

    if totalBytes > 0 {
      progressBar.isIndeterminate = false
      progressBar.minValue = 0
      progressBar.maxValue = Double(totalBytes)
      progressBar.doubleValue = 0
    } else {
      progressBar.isIndeterminate = true
    }
    progressBar.startAnimation(nil)

    guard let panel = panel else { return }
    if let parent = parent {
      // Re-parenting is harmless if we're already a child of `parent`.
      parent.addChildWindow(panel, ordered: .above)
    }
    if wasAlreadyVisible {
      // Subsequent files in a multi-file drop: just retarget the existing
      // panel in place, don't replay the slide-in.
      positionPanel(animated: false)
    } else {
      positionPanel(animated: true)
      panel.orderFront(nil)
    }
  }

  /// Update the progress bar and detail line. No-op if the panel isn't
  /// visible (i.e. `begin` was never called or `finish` already hid it).
  func update(copied: Int64, total: Int64, index: Int, count: Int) {
    guard let panel = panel, panel.isVisible else { return }
    if total > 0 {
      progressBar.isIndeterminate = false
      progressBar.doubleValue = Double(min(copied, total))
    }
    detailLabel.stringValue = formatDetail(copied: copied, total: total, index: index, count: count)
  }

  /// Flash a final state and schedule the panel to hide. Pass `cancelled:
  /// true` when the copy ended because the user clicked ⊗; that surfaces
  /// "Cancelled" instead of "Copy failed".
  func finish(success: Bool, cancelled: Bool = false) {
    guard let panel = panel else { return }
    cancelButton.isEnabled = false
    currentToken = nil
    progressBar.stopAnimation(nil)

    let hideDelay: TimeInterval
    if success {
      progressBar.isIndeterminate = false
      progressBar.doubleValue = progressBar.maxValue
      // NSProgressIndicator has an undocumented ~0.3 s smooth-fill animation
      // when doubleValue jumps. Delay "Done" until the bar visibly catches up
      // so the text doesn't lead the fill. Extend the hide so "Done" still
      // gets ~0.7 s of visibility once it appears.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
        self?.detailLabel.stringValue = "Done"
      }
      hideDelay = 1.05
    } else if cancelled {
      detailLabel.stringValue = "Cancelled"
      hideDelay = 0.8
    } else {
      detailLabel.stringValue = "Copy failed"
      hideDelay = 0.8
    }

    let work = DispatchWorkItem { [weak self] in
      self?.hide()
    }
    hideWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
    _ = panel
  }

  @objc private func cancelClicked() {
    // Flip the token; the copy loop notices on its next chunk boundary and
    // throws DropCopyCancelled, which the caller turns into finish(cancelled:).
    currentToken?.cancel()
    cancelButton.isEnabled = false
    detailLabel.stringValue = "Cancelling…"
  }

  private func hide() {
    guard let panel = panel else { return }
    if let parent = panel.parent {
      parent.removeChildWindow(panel)
    }
    panel.orderOut(nil)
    // Reset progress so the next drop doesn't flash the previous "Done" state
    // and then animate from 100% → 0% as `begin` resets it.
    progressBar.stopAnimation(nil)
    progressBar.isIndeterminate = false
    progressBar.doubleValue = 0
  }

  private func ensurePanel() {
    if panel != nil { return }

    let contentRect = NSRect(x: 0, y: 0, width: 320, height: 78)
    let p = NSPanel(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    p.isFloatingPanel = true
    p.becomesKeyOnlyIfNeeded = true
    p.hidesOnDeactivate = false
    p.isReleasedWhenClosed = false
    p.backgroundColor = .clear
    p.isOpaque = false
    p.hasShadow = true
    p.level = .floating

    // Vibrant rounded background — HUD-style, matches notification banners.
    let effect = NSVisualEffectView(frame: contentRect)
    effect.material = .hudWindow
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 14
    effect.layer?.masksToBounds = true
    p.contentView = effect

    let title = NSTextField(labelWithString: "")
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    title.textColor = .labelColor
    title.lineBreakMode = .byTruncatingMiddle
    title.translatesAutoresizingMaskIntoConstraints = false
    title.setContentHuggingPriority(.defaultLow, for: .horizontal)
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    effect.addSubview(title)

    // Top-right close button. SF Symbol `xmark.circle.fill` in secondary
    // label color so it reads as "dismiss" rather than competing with the
    // filename for attention.
    let btn = NSButton()
    btn.isBordered = false
    btn.bezelStyle = .regularSquare
    btn.imagePosition = .imageOnly
    btn.imageScaling = .scaleProportionallyDown
    btn.image = NSImage(
      systemSymbolName: "xmark.circle.fill",
      accessibilityDescription: "Cancel copy"
    )
    btn.contentTintColor = .secondaryLabelColor
    btn.target = self
    btn.action = #selector(cancelClicked)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.toolTip = "Cancel copy"
    effect.addSubview(btn)

    let bar = NSProgressIndicator()
    bar.style = .bar
    bar.isIndeterminate = false
    bar.controlSize = .small
    bar.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(bar)

    let detail = NSTextField(labelWithString: "")
    detail.font = .systemFont(ofSize: 11, weight: .regular)
    detail.textColor = .secondaryLabelColor
    detail.translatesAutoresizingMaskIntoConstraints = false
    detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
    detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    effect.addSubview(detail)

    NSLayoutConstraint.activate([
      // Title spans from the left padding to just before the close button.
      title.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
      title.trailingAnchor.constraint(equalTo: btn.leadingAnchor, constant: -6),
      title.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),

      // Close button: 18x18, hugging the top-right corner.
      btn.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
      btn.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      btn.widthAnchor.constraint(equalToConstant: 18),
      btn.heightAnchor.constraint(equalToConstant: 18),

      // Progress bar spans the full width below the title row.
      bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: btn.trailingAnchor),
      bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),

      // Detail line under the bar.
      detail.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
      detail.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
      detail.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
      detail.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10),
    ])

    self.panel = p
    self.titleLabel = title
    self.detailLabel = detail
    self.progressBar = bar
    self.cancelButton = btn
  }

  /// Position the panel inside the VM window's top-right corner, just below
  /// the titlebar, so it overlays the VM display. The toast remains a host
  /// NSPanel (child-windowed to the VM window) but visually sits on top of
  /// the guest content rather than floating outside the window's frame.
  /// When `animated` is true (first appearance of a drop session) the panel
  /// fades in over ~0.18 s; otherwise it snaps into place.
  private func positionPanel(animated: Bool) {
    guard let panel = panel, let parent = anchorWindow else { return }
    let parentFrame = parent.frame
    let size = panel.frame.size
    let rightInset: CGFloat = 12  // inset from window's right edge
    let topInset: CGFloat = 44    // clears standard titlebar + small gap

    let targetX = parentFrame.maxX - size.width - rightInset
    let targetY = parentFrame.maxY - size.height - topInset
    let targetFrame = NSRect(x: targetX, y: targetY, width: size.width, height: size.height)

    panel.setFrame(targetFrame, display: true)

    if animated {
      // Fade in from transparent. `animator().alphaValue` is the documented
      // animatable property on NSWindow (unlike setFrameOrigin, which is a
      // silent no-op via the animator proxy).
      panel.alphaValue = 0
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.18
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1
      }
    } else {
      panel.alphaValue = 1
    }
  }

  private func formatDetail(copied: Int64, total: Int64, index: Int, count: Int) -> String {
    let bcf = ByteCountFormatter()
    bcf.countStyle = .file
    let copiedStr = bcf.string(fromByteCount: max(0, copied))
    let totalStr = total > 0 ? bcf.string(fromByteCount: total) : "?"
    let prefix = count > 1 ? "[\(index)/\(count)] " : ""
    return "\(prefix)\(copiedStr) of \(totalStr)"
  }
}

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

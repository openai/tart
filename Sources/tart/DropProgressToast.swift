import AppKit
import Foundation

/// Borderless HUD-style panel shown over the VM window during a host→guest
/// drag-and-drop copy. Displays the filename, a determinate progress bar, and
/// a "[i/N] copied / total" detail line; auto-hides shortly after `finish`.
///
/// All methods MUST be called on the main thread. Callers driving copies from
/// a background queue should hop via `DispatchQueue.main.async` first.
///
/// Lifecycle:
///   begin(...)           -> panel appears as a child of the VM window
///   update(...)          -> progress bar advances (no-op if not visible)
///   finish(success:)     -> brief "Done" / "Failed" message, then auto-hide
///
/// Multiple files dropped in one gesture are copied serially by the caller;
/// `begin` may be invoked again before the previous `finish` has hidden the
/// panel — that just retargets the existing panel to the new file.
final class DropProgressToast {
  static let shared = DropProgressToast()

  private var panel: NSPanel?
  private var progressBar: NSProgressIndicator!
  private var titleLabel: NSTextField!
  private var detailLabel: NSTextField!
  private var hideWorkItem: DispatchWorkItem?
  private weak var anchorWindow: NSWindow?

  private init() {}

  /// Show the toast (or retarget it to a new file) and reset the progress bar.
  /// `parent` is the VM window; the panel becomes a child of it so it tracks
  /// movement and z-order. `totalBytes <= 0` flips the bar to indeterminate.
  func begin(parent: NSWindow?, filename: String, totalBytes: Int64, index: Int, count: Int) {
    ensurePanel()
    hideWorkItem?.cancel()
    hideWorkItem = nil

    anchorWindow = parent
    titleLabel.stringValue = filename
    detailLabel.stringValue = formatDetail(copied: 0, total: totalBytes, index: index, count: count)

    if totalBytes > 0 {
      progressBar.isIndeterminate = false
      progressBar.minValue = 0
      progressBar.maxValue = Double(totalBytes)
      progressBar.doubleValue = 0
    } else {
      progressBar.isIndeterminate = true
    }
    progressBar.startAnimation(nil)

    positionPanel()
    guard let panel = panel else { return }
    if let parent = parent {
      // addChildWindow re-parents harmlessly even if already attached.
      parent.addChildWindow(panel, ordered: .above)
    } else {
      panel.orderFront(nil)
    }
  }

  /// Update the progress bar and detail line. No-op if the panel isn't visible
  /// (i.e. `begin` was never called or `finish` already hid it).
  func update(copied: Int64, total: Int64, index: Int, count: Int) {
    guard let panel = panel, panel.isVisible else { return }
    if total > 0 {
      progressBar.isIndeterminate = false
      progressBar.doubleValue = Double(min(copied, total))
    }
    detailLabel.stringValue = formatDetail(copied: copied, total: total, index: index, count: count)
  }

  /// Flash a "Done" or "Copy failed" state and schedule the panel to hide
  /// after a short delay so the user sees the final state.
  func finish(success: Bool) {
    guard let panel = panel else { return }
    if success {
      progressBar.isIndeterminate = false
      progressBar.doubleValue = progressBar.maxValue
      detailLabel.stringValue = "Done"
    } else {
      detailLabel.stringValue = "Copy failed"
    }
    progressBar.stopAnimation(nil)

    let work = DispatchWorkItem { [weak self] in
      self?.hide()
    }
    hideWorkItem = work
    // 0.8s lets the user register the final state without lingering forever.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    _ = panel  // silence warning about unused panel
  }

  private func hide() {
    guard let panel = panel else { return }
    if let parent = panel.parent {
      parent.removeChildWindow(panel)
    }
    panel.orderOut(nil)
  }

  private func ensurePanel() {
    if panel != nil { return }

    let contentRect = NSRect(x: 0, y: 0, width: 360, height: 78)
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

    // Vibrant rounded background — HUD-style.
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
      title.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
      title.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
      title.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),

      bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: title.trailingAnchor),
      bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),

      detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
      detail.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
      detail.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10),
    ])

    self.panel = p
    self.titleLabel = title
    self.detailLabel = detail
    self.progressBar = bar
  }

  /// Center the panel along the VM window's bottom edge with a small inset.
  /// Falls back to no-op if we don't have an anchor window.
  private func positionPanel() {
    guard let panel = panel, let parent = anchorWindow else { return }
    let parentFrame = parent.frame
    let size = panel.frame.size
    let inset: CGFloat = 16
    let origin = NSPoint(
      x: parentFrame.midX - size.width / 2,
      y: parentFrame.minY + inset
    )
    panel.setFrameOrigin(origin)
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

/// Chunked file copy with throttled progress callbacks. Used by the drag-and-
/// drop handler to feed `DropProgressToast` without freezing the VM render
/// view (the previous synchronous `FileManager.copyItem` blocked the same
/// queue/view).
///
/// - Removes any existing file at `dst` first (drops semantically replace).
/// - Reports `progress(copied)` at most once every ~50 ms during the copy,
///   plus a final call at completion so the bar always reaches 100%.
/// - Throws if either side fails; partial output at `dst` is left in place
///   so the caller can decide how to surface the error.
enum DropProgressCopier {
  static func copy(
    from src: URL,
    to dst: URL,
    totalBytes: Int64,
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

    let chunkSize = 1 * 1024 * 1024  // 1 MiB — large enough to amortize syscalls,
    // small enough to stream progress on fast disks.
    let reportInterval: TimeInterval = 0.05
    var lastReport = Date(timeIntervalSince1970: 0)
    var copied: Int64 = 0

    while true {
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
    // Always fire a final callback so the UI reaches 100% even when the file
    // finished inside the throttle window.
    progress(copied)
  }
}

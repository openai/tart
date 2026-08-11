import AppKit
import Foundation

/// AppKit view construction, positioning, and detail-string formatting for
/// `DropProgressToast`. Split out from the toast's state/coordination logic so
/// each file stays focused; follows the codebase's `Type+Feature.swift`
/// extension-file convention.
extension DropProgressToast {
  func ensurePanel() {
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
  func positionPanel(animated: Bool) {
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

  func formatDetail(copied: Int64, total: Int64, index: Int, count: Int) -> String {
    let bcf = ByteCountFormatter()
    bcf.countStyle = .file
    let copiedStr = bcf.string(fromByteCount: max(0, copied))
    let prefix = count > 1 ? "[\(index)/\(count)] " : ""
    // Unknown total (stat failed / genuinely empty): show just what's copied
    // rather than the awkward "0 bytes of ?".
    guard total > 0 else { return "\(prefix)\(copiedStr)" }
    return "\(prefix)\(copiedStr) of \(bcf.string(fromByteCount: total))"
  }
}

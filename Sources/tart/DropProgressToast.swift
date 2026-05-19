import AppKit
import Foundation

/// Borderless HUD-style panel shown over the VM window during a host→guest
/// drag-and-drop copy. Renders like a macOS notification banner: anchored to
/// the top-right of the VM window, slides in from the right edge, shows the
/// filename / determinate bar / "[i/N] copied / total" detail line, and has
/// a close (⊗) button that cancels the in-flight copy.
///
/// All methods MUST be called on the main thread. Callers driving copies
/// from a background queue should hop via `DispatchQueue.main.async` first.
///
/// Every file gets a monotonically increasing `sessionID` (see
/// `DropSession.next()`). `update`/`finish`/`setFinalDestination` ignore any
/// call whose `sessionID` is not the one the most recent `begin` installed,
/// so a slow guest-relocation result for file 1 can't clobber or hide the
/// toast while file 2 of the same drop is still copying.
///
/// AppKit panel construction, positioning, and detail-string formatting live
/// in `DropProgressToast+Panel.swift`.
final class DropProgressToast {
  static let shared = DropProgressToast()

  var panel: NSPanel?
  var progressBar: NSProgressIndicator!
  var titleLabel: NSTextField!
  var detailLabel: NSTextField!
  var cancelButton: NSButton!
  private var hideWorkItem: DispatchWorkItem?
  weak var anchorWindow: NSWindow?
  /// Text that the delayed-final-text work item should apply when it fires.
  /// finish() sets this to "Done", setFinalDestination() upgrades it to
  /// "Copied to <folder>" — whichever value is current at +0.35 s wins, so a
  /// fast relocation result doesn't get clobbered by the placeholder.
  private var pendingFinalText: String = ""
  private var didApplyFinalText: Bool = false

  /// Identifies the file currently driving the toast. Stale callbacks (from a
  /// previous file's async relocation) carry an older id and are ignored.
  private var currentSessionID: Int = -1

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
    cancelToken: DropCancellationToken,
    sessionID: Int
  ) {
    ensurePanel()
    hideWorkItem?.cancel()
    hideWorkItem = nil

    let wasAlreadyVisible = (panel?.isVisible == true)

    anchorWindow = parent
    currentToken = cancelToken
    currentSessionID = sessionID

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
  /// visible or the call belongs to a superseded file.
  func update(copied: Int64, total: Int64, index: Int, count: Int, sessionID: Int) {
    guard sessionID == currentSessionID else { return }
    guard let panel = panel, panel.isVisible else { return }
    if total > 0 {
      progressBar.isIndeterminate = false
      progressBar.doubleValue = Double(min(copied, total))
    }
    detailLabel.stringValue = formatDetail(copied: copied, total: total, index: index, count: count)
  }

  /// Called once the guest-agent relocation completes (or fails) with the
  /// basename of the folder the file is in. Upgrades the pending final text
  /// to "Copied to <folder>" so the delayed apply uses it; if the apply
  /// already fired (relocation was slow), patches the label directly. No-op
  /// if the panel already hid or this is a stale (superseded) callback.
  /// Schedules the (short) hide now that the real destination is known.
  func setFinalDestination(_ folderName: String, sessionID: Int) {
    guard sessionID == currentSessionID else { return }
    guard let panel = panel, panel.isVisible, !folderName.isEmpty else { return }
    pendingFinalText = "Copied to \(folderName)"
    if didApplyFinalText {
      detailLabel.stringValue = pendingFinalText
    }
    hideWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.hide()
    }
    hideWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    _ = panel
  }

  /// Flash a final state and schedule the panel to hide. Pass `cancelled:
  /// true` when the copy ended because the user clicked ⊗. `destinationFolder`
  /// (only honored on success) is shown as "Copied to <folder>".
  ///
  /// When `awaitingRelocation` is true the file copied locally but the guest
  /// agent is still being asked where it should land; we keep the toast up on
  /// a long fallback timer (longer than the RPC's 5 s deadline) and let
  /// `setFinalDestination` drive the real, short hide. That way the user
  /// always sees the final destination instead of the toast vanishing at 2 s
  /// while a slow/again-prompting agent is still working.
  func finish(
    success: Bool,
    destinationFolder: String? = nil,
    cancelled: Bool = false,
    awaitingRelocation: Bool = false,
    sessionID: Int
  ) {
    guard sessionID == currentSessionID else { return }
    guard let panel = panel else { return }
    cancelButton.isEnabled = false
    currentToken = nil
    progressBar.stopAnimation(nil)

    let hideDelay: TimeInterval
    if success {
      progressBar.isIndeterminate = false
      progressBar.doubleValue = progressBar.maxValue
      // NSProgressIndicator has an undocumented ~0.3 s smooth-fill animation
      // when doubleValue jumps. Delay the final text until the bar visibly
      // catches up so the text doesn't lead the fill. setFinalDestination
      // may upgrade `pendingFinalText` to "Copied to <folder>" in that
      // window; the work item picks up whatever value is current at +0.35 s.
      if let folder = destinationFolder, !folder.isEmpty {
        pendingFinalText = "Copied to \(folder)"
      } else {
        pendingFinalText = "Done"
      }
      didApplyFinalText = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
        guard let self = self else { return }
        self.detailLabel.stringValue = self.pendingFinalText
        self.didApplyFinalText = true
      }
      // Awaiting the guest agent: hold on a fallback timer that outlives the
      // 5 s RPC deadline; setFinalDestination cancels it and hides shortly
      // after the real destination is known. Otherwise hide at the usual 2 s.
      hideDelay = awaitingRelocation ? 6.5 : 2.0
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

  @objc func cancelClicked() {
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
}

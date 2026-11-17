import Foundation
import XCTest
@testable import tart

final class LivePauseTests: XCTestCase {
  func testCommandsParseVMName() throws {
    XCTAssertEqual(try Pause.parse(["example"]).name, "example")
    XCTAssertEqual(try Resume.parse(["example"]).name, "example")
  }

  func testStalePauseMarkerDoesNotMakeStoppedVMPaused() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = VMDirectory(baseURL: root)
    try Data().write(to: directory.configURL)
    try Data().write(to: directory.pausedURL)
    XCTAssertEqual(try directory.state(), .Stopped)
    try Data().write(to: directory.stateURL)
    XCTAssertEqual(try directory.state(), .Suspended)
  }

  @MainActor
  func testPauseIsRejectedUntilInitializationCompletes() {
    let lifecycle = LivePauseLifecycle()
    XCTAssertFalse(lifecycle.beginTransition())
    lifecycle.initialized = true
    XCTAssertTrue(lifecycle.beginTransition())
    XCTAssertFalse(lifecycle.beginTransition())
    lifecycle.endTransition()
    XCTAssertTrue(lifecycle.beginTransition())
  }

  @MainActor
  func testSuspendWaitsForInitializationAndCoalescesRequests() {
    let lifecycle = LivePauseLifecycle()
    var saves = 0
    lifecycle.requestSuspend { saves += 1 }
    lifecycle.requestSuspend { saves += 100 }
    XCTAssertEqual(saves, 0)
    lifecycle.initialized = true
    XCTAssertEqual(saves, 1)
    XCTAssertFalse(lifecycle.beginTransition())
    lifecycle.endTransition()
    lifecycle.requestSuspend { saves += 100 }
    XCTAssertEqual(saves, 1)
  }

  @MainActor
  func testSuspendWaitsForActiveTransitionAndTakesPriority() {
    let lifecycle = LivePauseLifecycle()
    lifecycle.initialized = true
    XCTAssertTrue(lifecycle.beginTransition())
    var saves = 0
    lifecycle.requestSuspend { saves += 1 }
    XCTAssertEqual(saves, 0)
    lifecycle.endTransition()
    XCTAssertEqual(saves, 1)
    XCTAssertFalse(lifecycle.beginTransition())
    lifecycle.endTransition()
    XCTAssertEqual(saves, 1)
  }

  @MainActor
  func testSuspendStartsImmediatelyWhenReady() {
    let lifecycle = LivePauseLifecycle()
    lifecycle.initialized = true
    var saves = 0
    lifecycle.requestSuspend { saves += 1 }
    XCTAssertEqual(saves, 1)
  }

  @MainActor
  func testSavingAlreadyPausedVMDoesNotPauseAgain() async throws {
    try await pauseForStateSave(state: .paused) {
      XCTFail("An already-paused VM must be saved without a second pause")
      throw NSError(domain: "double-pause", code: 1)
    }
  }

  @MainActor
  func testSavingRunningVMPausesFirst() async throws {
    var paused = false
    try await pauseForStateSave(state: .running) { paused = true }
    XCTAssertTrue(paused)
  }

  @MainActor
  func testSavingStoppedVMIsRejected() async {
    do {
      try await pauseForStateSave(state: .stopped) {
        XCTFail("Stopped VMs cannot be paused")
      }
      XCTFail("Stopped VMs cannot be saved")
    } catch {}
  }

}

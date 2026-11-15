import ArgumentParser
import Foundation
import Darwin
import Virtualization

struct Pause: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Pause a VM in memory, retaining its process and RAM")
  @Argument var name: String
  func run() async throws { try await changeLiveState(name, paused: true) }
}
struct Resume: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Resume a VM paused in memory")
  @Argument var name: String
  func run() async throws { try await changeLiveState(name, paused: false) }
}
private func changeLiveState(_ name: String, paused: Bool) async throws {
  let directory = try VMStorageLocal().open(name)
  let pid = try directory.lock().pid()
  guard pid != 0 else { throw RuntimeError.VMNotRunning(name) }
  let desired: VMDirectory.State = paused ? .Paused : .Running
  if try directory.state() == desired { return }
  guard kill(pid, paused ? SIGURG : SIGCONT) == 0 else {
    throw RuntimeError.Generic("Failed to signal VM \(name)")
  }
  let deadline = ContinuousClock.now + .seconds(10)
  while ContinuousClock.now < deadline {
    if try directory.lock().pid() != pid { throw RuntimeError.VMNotRunning(name) }
    if try directory.state() == desired { return }
    try await Task.sleep(for: .milliseconds(100))
  }
  throw RuntimeError.Generic("VM \(name) did not acknowledge \(paused ? "pause" : "resume")")
}

// No execution may be paused while startup is still waiting on guest work
// (for example, the VNC IP-resolution deadline).
struct LivePauseLifecycle {
  var initialized = false
  private var transitioning = false

  mutating func beginTransition() -> Bool {
    guard initialized && !transitioning else { return false }
    transitioning = true
    return true
  }

  mutating func endTransition() {
    transitioning = false
  }
}

@MainActor
func pauseForStateSave(state: VZVirtualMachine.State, pause: () async throws -> Void) async throws {
  switch state {
  case .running:
    try await pause()
  case .paused:
    break
  default:
    throw RuntimeError.Generic("VM must be running or paused before saving state")
  }
}

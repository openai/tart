import ArgumentParser
import Foundation
import System
import SwiftDate

struct Stop: AsyncParsableCommand {
  static var configuration = CommandConfiguration(commandName: "stop", abstract: "Stop a VM")

  @Argument(help: "VM name", completion: .custom(completeRunningMachines))
  var name: String

  @Option(name: [.short, .long], help: "Seconds to wait for graceful termination before forcefully terminating the VM")
  var timeout: UInt64 = 30

  func run() async throws {
    let vmDir = try VMStorageLocal().open(name)
    switch try vmDir.state() {
    case .Suspended:
      try stopSuspended(vmDir)
    case .Running:
      try await stopRunning(vmDir)
    case .Stopped:
      throw RuntimeError.VMNotRunning(name)
    }
  }

  func stopSuspended(_ vmDir: VMDirectory) throws {
    try? FileManager.default.removeItem(at: vmDir.stateURL)
  }

  func stopRunning(_ vmDir: VMDirectory) async throws {
    let lock = try vmDir.lock()

    // Find the VM's PID
    var pid = try lock.pid()
    if pid == 0 {
      throw RuntimeError.VMNotRunning(name)
    }

    // Try to gracefully terminate the VM
    //
    // Note that we don't check the return code here
    // to provide a clean exit from "tart stop" in cases
    // when the VM is already shutting down and we hit
    // a race condition.
    //
    // We check the return code in the kill(2) below, though,
    // because it's a less common scenario and it would be
    // nice to know for the user that we've tried all methods
    // and failed to shutdown the VM.
    kill(pid, SIGINT)

    // Ensure that the VM has terminated
    var gracefulWaitDuration = Measurement(value: Double(timeout), unit: UnitDuration.seconds)
    let gracefulTickDuration = Measurement(value: Double(100), unit: UnitDuration.milliseconds)

    while gracefulWaitDuration.value > 0 {
      pid = try lock.pid()
      if pid == 0 {
        return
      }

      try await Task.sleep(nanoseconds: UInt64(gracefulTickDuration.converted(to: .nanoseconds).value))
      gracefulWaitDuration = gracefulWaitDuration - gracefulTickDuration
    }

    // Seems that VM is still running, proceed with forceful termination
    //
    // ESRCH means that the VM has exited on its own since our last check.
    let ret = kill(pid, SIGKILL)
    if ret != 0 && errno != ESRCH {
      let details = Errno(rawValue: CInt(errno))

      throw RuntimeError.VMTerminationFailed("failed to forcefully terminate the VM \"\(name)\": \(details)")
    }
  }
}

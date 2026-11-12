import ArgumentParser
import Foundation

struct Flatten: AsyncParsableCommand {
  static var configuration = CommandConfiguration(
    abstract: "Convert a stacked VM into a standalone VM",
    discussion: """
    Writes the VM's immutable base disk, its overlays and the VM's own writes into a single disk, \
    so that the VM no longer depends on Tart's cache and can be pushed as a new standalone image. \
    The cached disk files stay in place for other VMs and are pruned once nothing uses them.
    """
  )

  @Argument(help: "VM name", completion: .custom(completeLocalMachines))
  var name: String

  func run() async throws {
    // Acquire a global lock
    let lock = try FileLock(lockURL: Config().tartHomeDir)
    try lock.lock()
    defer { withExtendedLifetime(lock) {} }

    let localStorage = try VMStorageLocal()
    let vmDir = try localStorage.open(name)

    guard vmDir.isStackedVM else {
      throw ValidationError("VM \(name) doesn't have a stacked disk")
    }
    try DiskImageStack.requireSupport()

    let tmpVMDir = try VMDirectory.temporary()

    // Lock the temporary VM directory to prevent its garbage collection
    let tmpVMDirLock = try FileLock(lockURL: tmpVMDir.baseURL)
    try tmpVMDirLock.lock()

    do {
      let vmLock = try vmDir.flattenStacked(to: tmpVMDir)
      defer { withExtendedLifetime(vmLock) {} }

      try localStorage.move(name, from: tmpVMDir)
    } catch {
      try? tmpVMDir.removeFromDisk()

      throw error
    }
  }
}

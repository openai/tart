import ArgumentParser
import Foundation

struct Import: AsyncParsableCommand {
  static var configuration = CommandConfiguration(abstract: "Import VM from a compressed .tvm file")

  @Argument(help: "Path to a file created with \"tart export\".", completion: .file())
  var path: String

  @Argument(help: "Destination VM name.", completion: .custom(completeLocalMachines))
  var name: String

  func validate() throws {
    if name.contains("/") {
      throw ValidationError("<name> should be a local name")
    }
  }

  func run() async throws {
    let localStorage = try VMStorageLocal()

    // Create a temporary VM directory to which we will load the export file
    let tmpVMDir = try VMDirectory.temporary()
    defer {
      try? tmpVMDir.removeFromDisk()
    }

    // Lock the temporary VM directory to prevent it's garbage collection
    // while we're running
    let tmpVMDirLock = try FileLock(lockURL: tmpVMDir.baseURL)
    try tmpVMDirLock.lock()

    // Populate the temporary VM directory with the export file contents
    print("importing...")
    try tmpVMDir.importFromArchive(path: path)
    guard tmpVMDir.initialized else {
      throw RuntimeError.ImportFailed("archive does not contain a runnable VM")
    }

    try await withTaskCancellationHandler(operation: {
      // Acquire a global lock
      let lock = try FileLock(lockURL: Config().tartHomeDir)
      try lock.lock()

      // Re-generate the VM's MAC address importing it will result in address collision
      if try localStorage.hasVMsWithMACAddress(macAddress: tmpVMDir.macAddress()) {
        try tmpVMDir.regenerateMACAddress()
      }

      try localStorage.move(name, from: tmpVMDir)

      try lock.unlock()
    }, onCancel: {
      try? tmpVMDir.removeFromDisk()
    })
  }
}

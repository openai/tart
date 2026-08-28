import Foundation

class VMStorageLocal: PrunableStorage {
  let baseURL: URL

  init() throws {
    baseURL = try Config().tartHomeDir.appendingPathComponent("vms", isDirectory: true)
  }

  private func vmURL(_ name: String) -> URL {
    baseURL.appendingPathComponent(name, isDirectory: true)
  }

  func exists(_ name: String) -> Bool {
    VMDirectory(baseURL: vmURL(name)).initialized
  }

  func open(_ name: String) throws -> VMDirectory {
    let vmDir = VMDirectory(baseURL: vmURL(name))

    try vmDir.validate(userFriendlyName: name)

    try vmDir.baseURL.updateAccessDate()

    return vmDir
  }

  func create(_ name: String, overwrite: Bool = false) throws -> VMDirectory {
    let vmDir = VMDirectory(baseURL: vmURL(name))

    try vmDir.initialize(overwrite: overwrite)

    return vmDir
  }

  func move(_ name: String, from: VMDirectory) throws {
    _ = try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    try replace(VMDirectory(baseURL: vmURL(name)), with: from)
  }

  func rename(_ name: String, _ newName: String) throws {
    let source = VMDirectory(baseURL: vmURL(name))
    let destination = VMDirectory(baseURL: vmURL(newName))
    try replace(destination, with: source)
  }

  /// References in a manifest must not disappear while content GC is deciding
  /// whether their immutable disk files are still in use.
  private func replace(_ destination: VMDirectory, with source: VMDirectory) throws {
    // Replacing a running VM's directory unlinks its locked config and disks,
    // leaving a live VM that list and stop can no longer find by name.
    let destinationLock = FileManager.default.fileExists(atPath: destination.configURL.path)
      ? try destination.lock() : nil
    if let destinationLock, try !destinationLock.trylock() {
      throw RuntimeError.VMIsRunning(destination.name)
    }
    defer { withExtendedLifetime(destinationLock) {} }

    if FileManager.default.fileExists(atPath: source.manifestURL.path) ||
      FileManager.default.fileExists(atPath: destination.manifestURL.path) {
      let contentStore = try ContentStore()
      try contentStore.withPruneLock {
        _ = try FileManager.default.replaceItemAt(destination.baseURL, withItemAt: source.baseURL)
      }
    } else {
      _ = try FileManager.default.replaceItemAt(destination.baseURL, withItemAt: source.baseURL)
    }
  }

  func delete(_ name: String) throws {
    try VMDirectory(baseURL: vmURL(name)).delete()
  }

  func list() throws -> [(String, VMDirectory)] {
    do {
      return try FileManager.default.contentsOfDirectory(
        at: baseURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: .skipsSubdirectoryDescendants).compactMap { url in
        let vmDir = VMDirectory(baseURL: url)

        if !vmDir.initialized {
          return nil
        }

        return (vmDir.name, vmDir)
      }
    } catch {
      if error.isFileNotFound() {
        return []
      }

      throw error
    }
  }

  func prunables() throws -> [Prunable] {
    try list().map { (_, vmDir) in vmDir }.filter { try !$0.running() }
  }

  func hasVMsWithMACAddress(macAddress: String) throws -> Bool {
    try list().contains { try $1.macAddress() == macAddress }
  }
}

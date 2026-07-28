import Foundation
import Virtualization
import CryptoKit

struct VMDirectory: Prunable {
  enum State: String {
    case Running = "running"
    case Suspended = "suspended"
    case Stopped = "stopped"
  }

  var baseURL: URL

  var configURL: URL {
    baseURL.appendingPathComponent("config.json")
  }
  var diskURL: URL {
    baseURL.appendingPathComponent("disk.img")
  }
  var nvramURL: URL {
    baseURL.appendingPathComponent("nvram.bin")
  }
  var stateURL: URL {
    baseURL.appendingPathComponent("state.vzvmsave")
  }
  var manifestURL: URL {
    baseURL.appendingPathComponent("manifest.json")
  }
  var controlSocketURL: URL {
    URL(fileURLWithPath: "control.sock", relativeTo: baseURL)
  }

  var explicitlyPulledMark: URL {
    baseURL.appendingPathComponent(".explicitly-pulled")
  }

  var name: String {
    baseURL.lastPathComponent
  }

  var url: URL {
    baseURL
  }

  func lock() throws -> PIDLock {
    try PIDLock(lockURL: configURL)
  }

  func running() throws -> Bool {
    // The most common reason why PIDLock() instantiation fails is a race with "tart delete" (ENOENT),
    // which is fine to report as "not running".
    //
    // The other reasons are unlikely and the cost of getting a false positive is way less than
    // the cost of crashing with an exception when calling "tart list" on a busy machine, for example.
    guard let lock = try? lock() else {
      return false
    }

    return try lock.pid() != 0
  }

  func state() throws -> State {
    if try running() {
      return State.Running
    } else if FileManager.default.fileExists(atPath: stateURL.path) {
      return State.Suspended
    } else {
      return State.Stopped
    }
  }

  static func temporary() throws -> VMDirectory {
    let tmpDir = try Config().tartTmpDir.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: false)

    return VMDirectory(baseURL: tmpDir)
  }

  //Create tmp directory with hashing
  static func temporaryDeterministic(key: String) throws -> VMDirectory {
    let keyData = Data(key.utf8)
    let hash = Insecure.MD5.hash(data: keyData)
    // Convert hash to string
    let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
    let tmpDir = try Config().tartTmpDir.appendingPathComponent(hashString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    return VMDirectory(baseURL: tmpDir)
  }

  var initialized: Bool {
    FileManager.default.fileExists(atPath: configURL.path) &&
      FileManager.default.fileExists(atPath: diskURL.path) &&
      FileManager.default.fileExists(atPath: nvramURL.path)
  }

  func initialize(overwrite: Bool = false) throws {
    if !overwrite && initialized {
      throw RuntimeError.VMDirectoryAlreadyInitialized("VM directory is already initialized, preventing overwrite")
    }

    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true, attributes: nil)

    try? FileManager.default.removeItem(at: configURL)
    try? FileManager.default.removeItem(at: diskURL)
    try? FileManager.default.removeItem(at: nvramURL)
  }

  func validate(userFriendlyName: String) throws {
    if !FileManager.default.fileExists(atPath: baseURL.path) {
      throw RuntimeError.VMDoesNotExist(name: userFriendlyName)
    }

    if !initialized {
      throw RuntimeError.VMMissingFiles("VM is missing some of its files (\(configURL.lastPathComponent),"
        + " \(diskURL.lastPathComponent) or \(nvramURL.lastPathComponent))")
    }
  }

  func clone(to: VMDirectory, generateMAC: Bool) throws {
    try FileManager.default.copyItem(at: configURL, to: to.configURL)
    try FileManager.default.copyItem(at: nvramURL, to: to.nvramURL)
    try FileManager.default.copyItem(at: diskURL, to: to.diskURL)
    try? FileManager.default.copyItem(at: stateURL, to: to.stateURL)

    // Re-generate MAC address
    if generateMAC {
      try to.regenerateMACAddress()
    }
  }

  func macAddress() throws -> String {
    try VMConfig(fromURL: configURL).macAddress.string
  }

  func regenerateMACAddress() throws {
    var vmConfig = try VMConfig(fromURL: configURL)

    vmConfig.macAddress = VZMACAddress.randomLocallyAdministered()
    // cleanup state if any
    try? FileManager.default.removeItem(at: stateURL)

    try vmConfig.save(toURL: configURL)
  }

  func initializeLinuxMachineIdentifier() throws {
    var vmConfig = try VMConfig(fromURL: configURL)
    guard var vmLinux = vmConfig.platform as? Linux else {
      throw RuntimeError.VMConfigurationError("cannot initialize a Linux machine identifier on a non-Linux VM")
    }
    guard vmLinux.machineIdentifier == nil else {
      throw RuntimeError.VMConfigurationError(
        "cannot initialize a Linux machine identifier when one already exists"
      )
    }

    vmLinux.machineIdentifier = VZGenericMachineIdentifier()
    vmConfig.platform = vmLinux

    try vmConfig.save(toURL: configURL)
  }

  func resizeDisk(_ sizeGB: UInt16, format: DiskImageFormat = .raw) throws {
    let diskExists = FileManager.default.fileExists(atPath: diskURL.path)

    if diskExists {
      // Existing disk - resize it
      try resizeExistingDisk(sizeGB)
    } else {
      // New disk - create it with the specified format
      try createDisk(sizeGB: sizeGB, format: format)
    }
  }

  private func resizeExistingDisk(_ sizeGB: UInt16) throws {
    // Check if this is an ASIF disk by reading the VM config
    let vmConfig = try VMConfig(fromURL: configURL)

    if vmConfig.diskFormat == .asif {
      try resizeASIFDisk(sizeGB)
    } else {
      try resizeRawDisk(sizeGB)
    }
  }

  private func resizeRawDisk(_ sizeGB: UInt16) throws {
    let diskFileHandle = try FileHandle.init(forWritingTo: diskURL)
    let currentDiskFileLength = try diskFileHandle.seekToEnd()
    let desiredDiskFileLength = UInt64(sizeGB) * 1000 * 1000 * 1000

    if desiredDiskFileLength < currentDiskFileLength {
      let currentLengthHuman = ByteCountFormatter().string(fromByteCount: Int64(currentDiskFileLength))
      let desiredLengthHuman = ByteCountFormatter().string(fromByteCount: Int64(desiredDiskFileLength))
      throw RuntimeError.InvalidDiskSize("new disk size of \(desiredLengthHuman) should be larger " +
        "than the current disk size of \(currentLengthHuman)")
    } else if desiredDiskFileLength > currentDiskFileLength {
      try diskFileHandle.truncate(atOffset: desiredDiskFileLength)
    }
    try diskFileHandle.close()
  }

  private func resizeASIFDisk(_ sizeGB: UInt16) throws {
    do {
      let diskImageInfo = try Diskutil.imageInfo(diskURL)

      let currentSizeBytes = try diskImageInfo.totalBytes()
      let desiredSizeBytes = UInt64(sizeGB) * 1000 * 1000 * 1000

      if desiredSizeBytes < currentSizeBytes {
        let currentLengthHuman = ByteCountFormatter().string(fromByteCount: Int64(currentSizeBytes))
        let desiredLengthHuman = ByteCountFormatter().string(fromByteCount: Int64(desiredSizeBytes))

        throw RuntimeError.InvalidDiskSize("New disk size of \(desiredLengthHuman) should be larger " +
          "than the current disk size of \(currentLengthHuman)")
      } else if desiredSizeBytes > currentSizeBytes {
        // Resize the ASIF disk image using diskutil
        try performASIFResize(sizeGB)
      } else {
        // If sizes are equal, no action needed
      }
    } catch let error as RuntimeError {
      throw error
    } catch {
      throw RuntimeError.FailedToResizeDisk("\(error)")
    }
  }

  private func performASIFResize(_ sizeGB: UInt16) throws {
    guard let diskutilURL = resolveBinaryPath("diskutil") else {
      throw RuntimeError.FailedToResizeDisk("diskutil not found in PATH")
    }

    let process = Process()
    process.executableURL = diskutilURL
    process.arguments = [
      "image", "resize",
      "--size", "\(sizeGB)G",
      diskURL.path
    ]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
      try process.run()
      process.waitUntilExit()

      let data = pipe.fileHandleForReading.readDataToEndOfFile()

      if process.terminationStatus != 0 {
        let output = String(data: data, encoding: .utf8) ?? "Unknown error"
        throw RuntimeError.FailedToResizeDisk("Failed to resize ASIF disk image: \(output)")
      }
    } catch {
      throw RuntimeError.FailedToResizeDisk("Failed to execute diskutil resize: \(error)")
    }
  }

  private func createDisk(sizeGB: UInt16, format: DiskImageFormat) throws {
    switch format {
    case .raw:
      try createRawDisk(sizeGB: sizeGB)
    case .asif:
      try Diskutil.imageCreate(diskURL: diskURL, sizeGB: sizeGB)
    }
  }

  private func createRawDisk(sizeGB: UInt16) throws {
    // Create traditional raw disk image
    FileManager.default.createFile(atPath: diskURL.path, contents: nil, attributes: nil)

    let diskFileHandle = try FileHandle.init(forWritingTo: diskURL)
    let desiredDiskFileLength = UInt64(sizeGB) * 1000 * 1000 * 1000
    try diskFileHandle.truncate(atOffset: desiredDiskFileLength)
    try diskFileHandle.close()
  }


  func delete() throws {
    let lock = try lock()

    if try !lock.trylock() {
      throw RuntimeError.VMIsRunning(name)
    }

    try FileManager.default.removeItem(at: baseURL)

    try lock.unlock()
  }

  func accessDate() throws -> Date {
    try baseURL.accessDate()
  }

  func allocatedSizeBytes() throws -> Int {
    try configURL.allocatedSizeBytes() + diskURL.allocatedSizeBytes() + nvramURL.allocatedSizeBytes()
  }

  func allocatedSizeGB() throws -> Int {
    try allocatedSizeBytes() / 1000 / 1000 / 1000
  }

  func deduplicatedSizeBytes() throws -> Int {
    try configURL.deduplicatedSizeBytes() + diskURL.deduplicatedSizeBytes() + nvramURL.deduplicatedSizeBytes()
  }

  func deduplicatedSizeGB() throws -> Int {
    try deduplicatedSizeBytes() / 1000 / 1000 / 1000
  }

  func sizeBytes() throws -> Int {
    try configURL.sizeBytes() + diskURL.sizeBytes() + nvramURL.sizeBytes()
  }

  func sizeGB() throws -> Int {
    try sizeBytes() / 1000 / 1000 / 1000
  }

  func diskSizeBytes() throws -> Int {
    let vmConfig = try VMConfig(fromURL: configURL)

    return switch vmConfig.diskFormat {
    case .raw:
      try sizeBytes()
    case .asif:
      try Diskutil.imageInfo(diskURL).totalBytes()
    }
  }

  func diskSizeGB() throws -> Int {
    try diskSizeBytes() / 1000 / 1000 / 1000
  }

  func markExplicitlyPulled() {
    FileManager.default.createFile(atPath: explicitlyPulledMark.path, contents: nil)
  }

  func isExplicitlyPulled() -> Bool {
    FileManager.default.fileExists(atPath: explicitlyPulledMark.path)
  }
}

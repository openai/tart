import Virtualization
import XCTest

@testable import tart

final class MemoryBalloonTests: XCTestCase {
  // Linux guests generally ship with the virtio_balloon driver,
  // so they get the memory balloon device out of the box
  func testAttachedForLinuxGuests() throws {
    let memoryBalloonDevices = try craftConfiguration().memoryBalloonDevices

    XCTAssertEqual(memoryBalloonDevices.count, 1)
    XCTAssertTrue(memoryBalloonDevices.first is VZVirtioTraditionalMemoryBalloonDeviceConfiguration)
  }

  // macOS guests show little to no practical memory reduction,
  // so there's no point in attaching the device to them
  func testNotAttachedForMacOSGuests() throws {
    XCTAssertEqual(try craftConfiguration(os: .darwin).memoryBalloonDevices.count, 0)
  }

  // Similarly to the entropy device, the memory balloon device is not
  // attached to suspendable VMs to not interfere with the save/restore support
  func testNotAttachedForSuspendableVMs() throws {
    XCTAssertEqual(try craftConfiguration(suspendable: true).memoryBalloonDevices.count, 0)
  }

  // The guest is squeezed down to the smallest size
  // that Virtualization.Framework allows
  func testMinimumBalloonTargetMemorySize() throws {
    var vmConfig = VMConfig(platform: Linux(), cpuCountMin: 1, memorySizeMin: 4096 * 1024 * 1024)
    try vmConfig.setMemory(memorySize: 8192 * 1024 * 1024)

    XCTAssertEqual(VM.minimumBalloonTargetMemorySize(vmConfig: vmConfig),
                   VZVirtualMachineConfiguration.minimumAllowedMemorySize)
  }

  // ...unless the VM is configured with even less memory than that,
  // in which case Virtualization.Framework would reject the target
  func testMinimumBalloonTargetMemorySizeNeverExceedsConfiguredMemory() throws {
    let tinyMemorySize = VZVirtualMachineConfiguration.minimumAllowedMemorySize / 2
    let vmConfig = VMConfig(platform: Linux(), cpuCountMin: 1, memorySizeMin: tinyMemorySize)

    XCTAssertEqual(VM.minimumBalloonTargetMemorySize(vmConfig: vmConfig), tinyMemorySize)
  }

  private func craftConfiguration(os: OS = .linux, suspendable: Bool = false) throws -> VZVirtualMachineConfiguration {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let vmDir = VMDirectory(baseURL: tmpDir)

    _ = try VZEFIVariableStore(creatingVariableStoreAt: vmDir.nvramURL)

    FileManager.default.createFile(atPath: vmDir.diskURL.path, contents: nil)
    let diskFileHandle = try FileHandle(forWritingTo: vmDir.diskURL)
    try diskFileHandle.truncate(atOffset: 512 * 1024 * 1024)
    try diskFileHandle.close()

    var vmConfig = VMConfig(platform: Linux(), cpuCountMin: 1, memorySizeMin: 1024 * 1024 * 1024)
    try vmConfig.save(toURL: vmDir.configURL)
    vmConfig.os = os

    // Note: VM.buildConfiguration() is used here instead of VM.craftConfiguration(),
    // because the latter additionally validates the configuration, which requires
    // the "com.apple.security.virtualization" entitlement that tests don't have
    return try VM.buildConfiguration(
      vmDir: vmDir,
      nvramURL: vmDir.nvramURL,
      vmConfig: vmConfig,
      additionalStorageDevices: [],
      directorySharingDevices: [],
      serialPorts: [],
      suspendable: suspendable
    )
  }
}

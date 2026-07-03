import Virtualization
import XCTest

@testable import tart

final class MemoryBalloonTests: XCTestCase {
  // Configurations created by older Tart versions don't have
  // the "memoryBalloon" key and should default to a disabled
  // memory balloon device
  func testDisabledByDefaultWhenDecodingLegacyConfig() throws {
    let legacyConfigJSON = """
    {
      "version": 1,
      "os": "linux",
      "arch": "arm64",
      "cpuCountMin": 1,
      "cpuCount": 1,
      "memorySizeMin": 536870912,
      "memorySize": 536870912,
      "macAddress": "5a:00:00:00:00:01"
    }
    """

    let vmConfig = try VMConfig(fromJSON: legacyConfigJSON.data(using: .utf8)!)

    XCTAssertFalse(vmConfig.memoryBalloon)
  }

  func testDisabledByDefaultWhenCreatingNewConfig() throws {
    let vmConfig = VMConfig(platform: Linux(), cpuCountMin: 1, memorySizeMin: 512 * 1024 * 1024)

    XCTAssertFalse(vmConfig.memoryBalloon)

    // The key shouldn't even be present in the resulting JSON to keep
    // the configurations of VMs that don't use this feature identical
    // to those produced by older Tart versions
    let encodedConfig = String(data: try vmConfig.toJSON(), encoding: .utf8)!
    XCTAssertFalse(encodedConfig.contains("memoryBalloon"))
  }

  func testPersistsWhenEnabled() throws {
    var vmConfig = VMConfig(platform: Linux(), cpuCountMin: 1, memorySizeMin: 512 * 1024 * 1024)
    vmConfig.memoryBalloon = true

    let roundtrippedVMConfig = try VMConfig(fromJSON: try vmConfig.toJSON())

    XCTAssertTrue(roundtrippedVMConfig.memoryBalloon)
  }

  func testMemoryBalloonSetArgumentParsing() throws {
    XCTAssertEqual(try tart.Set.parse(["vm", "--memory-balloon", "true"]).memoryBalloon, true)
    XCTAssertEqual(try tart.Set.parse(["vm", "--memory-balloon", "false"]).memoryBalloon, false)
    XCTAssertNil(try tart.Set.parse(["vm"]).memoryBalloon)
    XCTAssertThrowsError(try tart.Set.parse(["vm", "--memory-balloon", "yes"]))
  }

  func testBalloonTargetMemoryValidation() throws {
    var vmConfig = VMConfig(platform: Linux(), cpuCountMin: 1, memorySizeMin: 4096 * 1024 * 1024)

    // Balloon device is not enabled
    XCTAssertThrowsError(try Run.validateBalloonTargetMemory(2048, vmConfig: vmConfig))

    vmConfig.memoryBalloon = true

    // Target exceeds the configured memory size
    XCTAssertThrowsError(try Run.validateBalloonTargetMemory(8192, vmConfig: vmConfig))

    // Target multiplication by 1 MB overflows UInt64
    XCTAssertThrowsError(try Run.validateBalloonTargetMemory(UInt64.max, vmConfig: vmConfig))

    // Target is too small to be safe
    XCTAssertThrowsError(try Run.validateBalloonTargetMemory(1, vmConfig: vmConfig))

    // Sane target
    XCTAssertNoThrow(try Run.validateBalloonTargetMemory(2048, vmConfig: vmConfig))

    // Target that is exactly the configured memory size (fully deflated balloon)
    XCTAssertNoThrow(try Run.validateBalloonTargetMemory(4096, vmConfig: vmConfig))
  }

  func testBalloonTargetMemoryValidationRespectsDarwinMinimum() throws {
    // A macOS guest whose restore image requires 4096 MB of memory at minimum
    var vmConfig = VMConfig(platform: Linux(), cpuCountMin: 1, memorySizeMin: 4096 * 1024 * 1024)
    vmConfig.os = .darwin
    vmConfig.memoryBalloon = true
    try vmConfig.setMemory(memorySize: 8192 * 1024 * 1024)

    // Target below the restore image's minimum supported memory size
    XCTAssertThrowsError(try Run.validateBalloonTargetMemory(2048, vmConfig: vmConfig))

    // Target at the restore image's minimum supported memory size
    XCTAssertNoThrow(try Run.validateBalloonTargetMemory(4096, vmConfig: vmConfig))

    // The same minimum doesn't apply to Linux guests, similarly
    // to how "tart set --memory" doesn't restrict them
    vmConfig.os = .linux
    XCTAssertNoThrow(try Run.validateBalloonTargetMemory(2048, vmConfig: vmConfig))
  }

  func testBalloonDeviceOnlyConfiguredWhenEnabled() throws {
    // Disabled by default
    XCTAssertEqual(try craftConfiguration().memoryBalloonDevices.count, 0)

    // Configured when enabled
    let memoryBalloonDevices = try craftConfiguration(memoryBalloon: true).memoryBalloonDevices
    XCTAssertEqual(memoryBalloonDevices.count, 1)
    XCTAssertTrue(memoryBalloonDevices.first is VZVirtioTraditionalMemoryBalloonDeviceConfiguration)

    // Not configured for suspendable VMs, even when enabled
    XCTAssertEqual(try craftConfiguration(memoryBalloon: true, suspendable: true).memoryBalloonDevices.count, 0)
  }

  private func craftConfiguration(memoryBalloon: Bool = false, suspendable: Bool = false) throws -> VZVirtualMachineConfiguration {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let nvramURL = tmpDir.appendingPathComponent("nvram.bin")
    _ = try VZEFIVariableStore(creatingVariableStoreAt: nvramURL)

    let diskURL = tmpDir.appendingPathComponent("disk.img")
    FileManager.default.createFile(atPath: diskURL.path, contents: nil)
    let diskFileHandle = try FileHandle(forWritingTo: diskURL)
    try diskFileHandle.truncate(atOffset: 512 * 1024 * 1024)
    try diskFileHandle.close()

    var vmConfig = VMConfig(platform: Linux(), cpuCountMin: 1, memorySizeMin: 1024 * 1024 * 1024)
    vmConfig.memoryBalloon = memoryBalloon

    // Note: VM.buildConfiguration() is used here instead of VM.craftConfiguration(),
    // because the latter additionally validates the configuration, which requires
    // the "com.apple.security.virtualization" entitlement that tests don't have
    return try VM.buildConfiguration(
      diskURL: diskURL,
      nvramURL: nvramURL,
      vmConfig: vmConfig,
      additionalStorageDevices: [],
      directorySharingDevices: [],
      serialPorts: [],
      suspendable: suspendable
    )
  }
}

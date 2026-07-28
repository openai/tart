import XCTest
@testable import tart

import Foundation
import Virtualization

final class VMConfigTests: XCTestCase {
  func testVMDisplayConfig() throws {
    // Defaults units (points)
    var vmDisplayConfig = VMDisplayConfig.init(argument: "1234x5678")
    XCTAssertEqual(VMDisplayConfig(width: 1234, height: 5678, unit: nil), vmDisplayConfig)

    // Explicit units (points)
    vmDisplayConfig = VMDisplayConfig.init(argument: "1234x5678pt")
    XCTAssertEqual(VMDisplayConfig(width: 1234, height: 5678, unit: .point), vmDisplayConfig)

    // Explicit units (pixels)
    vmDisplayConfig = VMDisplayConfig.init(argument: "1234x5678px")
    XCTAssertEqual(VMDisplayConfig(width: 1234, height: 5678, unit: .pixel), vmDisplayConfig)
  }

  func testLinuxMachineIdentifierSerialization() throws {
    let originalIdentifier = VZGenericMachineIdentifier()
    let originalConfig = VMConfig(
      platform: Linux(machineIdentifier: originalIdentifier), cpuCountMin: 2, memorySizeMin: 1024 * 1024 * 1024
    )
    let encodedConfigData = try originalConfig.toJSON()

    let decodedConfig = try VMConfig(fromJSON: encodedConfigData)
    let decodedLinux = try XCTUnwrap(decodedConfig.platform as? Linux)
    let decodedMachineIdentifier = try XCTUnwrap(decodedLinux.machineIdentifier)

    XCTAssertEqual(
      decodedMachineIdentifier.dataRepresentation,
      originalIdentifier.dataRepresentation,
      "decoded machine identifier should match original identifier"
    )

    let platformConfiguration = try decodedLinux.platform(
      nvramURL: URL(fileURLWithPath: "/dev/null"),
      needsNestedVirtualization: false
    )
    let decodedPlatformConfiguration = try XCTUnwrap(
      platformConfiguration as? VZGenericPlatformConfiguration
    )

    XCTAssertEqual(
      decodedPlatformConfiguration.machineIdentifier.dataRepresentation,
      originalIdentifier.dataRepresentation,
      "platform configuration should reuse decoded machine identifier"
    )
  }

  func testLegacyLinuxConfigWithoutMachineIdentifier() throws {
    let originalIdentifier = VZGenericMachineIdentifier()
    let originalConfig = VMConfig(
      platform: Linux(machineIdentifier: originalIdentifier), cpuCountMin: 2, memorySizeMin: 1024 * 1024 * 1024
    )
    let encodedConfigData = try originalConfig.toJSON()

    var configJSONObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedConfigData) as? [String: Any])
    configJSONObject.removeValue(forKey: "machineIdentifier")
    let legacyConfigData = try JSONSerialization.data(withJSONObject: configJSONObject)

    let decodedConfig = try VMConfig(fromJSON: legacyConfigData)
    let decodedLinux = try XCTUnwrap(decodedConfig.platform as? Linux)

    XCTAssertNil(decodedLinux.machineIdentifier, "missing machineIdentifier should be decoded as nil")
  }
}

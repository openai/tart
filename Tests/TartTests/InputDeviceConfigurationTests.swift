import Virtualization
import XCTest
@testable import tart

final class InputDeviceConfigurationTests: XCTestCase {
  func testLinuxUSBInputsCanBeDisabled() {
    let configuration = VZVirtualMachineConfiguration()

    VM.configureInputDevices(configuration, platform: Linux())
    XCTAssertEqual(configuration.keyboards.count, 1)
    XCTAssertTrue(configuration.keyboards.contains { $0 is VZUSBKeyboardConfiguration })
    XCTAssertEqual(configuration.pointingDevices.count, 1)
    XCTAssertTrue(configuration.pointingDevices.contains { $0 is VZUSBScreenCoordinatePointingDeviceConfiguration })

    VM.configureInputDevices(configuration, platform: Linux(), noUSBAccessories: true)
    XCTAssertTrue(configuration.keyboards.isEmpty)
    XCTAssertTrue(configuration.pointingDevices.isEmpty)

    VM.configureInputDevices(configuration, platform: Linux(), noUSBAccessories: true, noTrackpad: true)
    XCTAssertTrue(configuration.keyboards.isEmpty)
    XCTAssertTrue(configuration.pointingDevices.isEmpty)
  }

  #if arch(arm64)
    func testMacOS13RetainsItsNativeTrackpad() {
      let platform = MacInputPlatform(nativeKeyboard: false)
      let configuration = VZVirtualMachineConfiguration()

      VM.configureInputDevices(configuration, platform: platform)
      XCTAssertEqual(configuration.keyboards.count, 1)
      XCTAssertEqual(configuration.pointingDevices.count, 2)

      VM.configureInputDevices(configuration, platform: platform, noUSBAccessories: true)
      XCTAssertTrue(configuration.keyboards.isEmpty)
      XCTAssertEqual(configuration.pointingDevices.count, 1)
      XCTAssertTrue(configuration.pointingDevices.contains { $0 is VZMacTrackpadConfiguration })
    }

    func testMacOS14RetainsBothNativeInputs() throws {
      guard #available(macOS 14, *) else {
        throw XCTSkip("Mac keyboards require macOS 14")
      }

      let configuration = VZVirtualMachineConfiguration()
      VM.configureInputDevices(configuration, platform: MacInputPlatform(nativeKeyboard: true), noUSBAccessories: true)

      XCTAssertEqual(configuration.keyboards.count, 1)
      XCTAssertTrue(configuration.keyboards.contains { $0 is VZMacKeyboardConfiguration })
      XCTAssertEqual(configuration.pointingDevices.count, 1)
      XCTAssertTrue(configuration.pointingDevices.contains { $0 is VZMacTrackpadConfiguration })
    }

    func testInputFlagsStillSelectTheExpectedDevices() throws {
      guard #available(macOS 14, *) else {
        throw XCTSkip("Mac keyboards require macOS 14")
      }

      let platform = MacInputPlatform(nativeKeyboard: true)
      for noUSBAccessories in [false, true] {
        for noKeyboard in [false, true] {
          for noPointer in [false, true] {
            for noTrackpad in [false, true] {
              let configuration = VZVirtualMachineConfiguration()
              VM.configureInputDevices(
                configuration,
                platform: platform,
                noUSBAccessories: noUSBAccessories,
                noTrackpad: noTrackpad,
                noPointer: noPointer,
                noKeyboard: noKeyboard
              )

              XCTAssertEqual(configuration.keyboards.contains { $0 is VZUSBKeyboardConfiguration }, !noUSBAccessories && !noKeyboard)
              XCTAssertEqual(configuration.keyboards.contains { $0 is VZMacKeyboardConfiguration }, !noKeyboard)
              XCTAssertEqual(configuration.pointingDevices.contains { $0 is VZUSBScreenCoordinatePointingDeviceConfiguration }, !noUSBAccessories && !noPointer)
              XCTAssertEqual(configuration.pointingDevices.contains { $0 is VZMacTrackpadConfiguration }, !noPointer && !noTrackpad)
            }
          }
        }
      }
    }

    func testSuspendableFallbackCannotReintroduceUSBInputs() {
      let configuration = VZVirtualMachineConfiguration()
      let platform = MacInputPlatform(nativeKeyboard: false)
      VM.configureInputDevices(configuration, platform: platform, suspendable: true)
      XCTAssertEqual(configuration.keyboards.count, 1)
      XCTAssertEqual(configuration.pointingDevices.count, 2)

      VM.configureInputDevices(
        configuration,
        platform: platform,
        suspendable: true,
        noUSBAccessories: true
      )

      XCTAssertTrue(configuration.keyboards.isEmpty)
      XCTAssertEqual(configuration.pointingDevices.count, 1)
      XCTAssertTrue(configuration.pointingDevices.contains { $0 is VZMacTrackpadConfiguration })
    }
  #endif
}

#if arch(arm64)
  // Model macOS 13 and 14 input availability without requiring a second host.
  private struct MacInputPlatform: PlatformSuspendable {
    var nativeKeyboard: Bool

    func os() -> OS { .darwin }

    func bootLoader(nvramURL: URL) throws -> VZBootLoader {
      try Linux().bootLoader(nvramURL: nvramURL)
    }

    func platform(nvramURL: URL, needsNestedVirtualization: Bool) throws -> VZPlatformConfiguration {
      try Linux().platform(nvramURL: nvramURL, needsNestedVirtualization: needsNestedVirtualization)
    }

    func graphicsDevice(vmConfig: VMConfig) -> VZGraphicsDeviceConfiguration {
      Linux().graphicsDevice(vmConfig: vmConfig)
    }

    func keyboards(noUSB: Bool) -> [VZKeyboardConfiguration] {
      var devices: [VZKeyboardConfiguration] = noUSB ? [] : [VZUSBKeyboardConfiguration()]
      if nativeKeyboard, #available(macOS 14, *) {
        devices.append(VZMacKeyboardConfiguration())
      }
      return devices
    }

    func pointingDevices(noUSB: Bool) -> [VZPointingDeviceConfiguration] {
      var devices: [VZPointingDeviceConfiguration] = noUSB ? [] : [VZUSBScreenCoordinatePointingDeviceConfiguration()]
      devices.append(VZMacTrackpadConfiguration())
      return devices
    }

    func pointingDevicesSimplified(noUSB: Bool) -> [VZPointingDeviceConfiguration] {
      noUSB ? [] : [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    func keyboardsSuspendable(noUSB: Bool) -> [VZKeyboardConfiguration] {
      if nativeKeyboard, #available(macOS 14, *) {
        return [VZMacKeyboardConfiguration()]
      }
      return keyboards(noUSB: noUSB)
    }

    func pointingDevicesSuspendable(noUSB: Bool) -> [VZPointingDeviceConfiguration] {
      nativeKeyboard ? [VZMacTrackpadConfiguration()] : pointingDevices(noUSB: noUSB)
    }
  }
#endif

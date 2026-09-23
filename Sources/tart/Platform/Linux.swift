import Virtualization

@available(macOS 13, *)
struct Linux: Platform {
  func os() -> OS {
    .linux
  }

  func bootLoader(nvramURL: URL) throws -> VZBootLoader {
    let result = VZEFIBootLoader()

    result.variableStore = VZEFIVariableStore(url: nvramURL)

    return result
  }

  func platform(nvramURL: URL, needsNestedVirtualization: Bool) throws -> VZPlatformConfiguration {
    let config = VZGenericPlatformConfiguration()
    if #available(macOS 15, *) {
      config.isNestedVirtualizationEnabled = needsNestedVirtualization
    }
    return config
  }

  func graphicsDevice(vmConfig: VMConfig) -> VZGraphicsDeviceConfiguration {
    let result = VZVirtioGraphicsDeviceConfiguration()

    result.scanouts = [
      VZVirtioGraphicsScanoutConfiguration(
        widthInPixels: vmConfig.display.width,
        heightInPixels: vmConfig.display.height
      )
    ]

    return result
  }

  func keyboards(noUSB: Bool) -> [VZKeyboardConfiguration] {
    noUSB ? [] : [VZUSBKeyboardConfiguration()]
  }

  func pointingDevices(noUSB: Bool) -> [VZPointingDeviceConfiguration] {
    noUSB ? [] : [VZUSBScreenCoordinatePointingDeviceConfiguration()]
  }

  func pointingDevicesSimplified(noUSB: Bool) -> [VZPointingDeviceConfiguration] {
    // Linux doesn't support trackpad, so just return the regular pointing devices
    return pointingDevices(noUSB: noUSB)
  }
}

import Virtualization

@available(macOS 13, *)
struct Linux: PlatformSuspendable {

  var machineIdentifier: VZGenericMachineIdentifier?

  init(machineIdentifier: VZGenericMachineIdentifier = VZGenericMachineIdentifier()) {
    self.machineIdentifier = machineIdentifier
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    guard let encodedMachineIdentifier = try container.decodeIfPresent(
      String.self, forKey: .machineIdentifier
    ) else {
      self.machineIdentifier = nil
      return
    }
    guard let data = Data.init(base64Encoded: encodedMachineIdentifier) else {
      throw DecodingError.dataCorruptedError(forKey: .machineIdentifier,
                                             in: container,
                                             debugDescription: "failed to initialize Data using the provided value")
    }
    guard let machineIdentifier = VZGenericMachineIdentifier.init(dataRepresentation: data) else {
      throw DecodingError.dataCorruptedError(forKey: .machineIdentifier,
                                             in: container,
                                             debugDescription: "failed to initialize VZGenericMachineIdentifier using the provided value")
    }
    self.machineIdentifier = machineIdentifier
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    try container.encodeIfPresent(machineIdentifier?.dataRepresentation.base64EncodedString(), forKey: .machineIdentifier)
  }

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

    if let machineIdentifier {
      config.machineIdentifier = machineIdentifier
    }

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

  func keyboards() -> [VZKeyboardConfiguration] {
    [VZUSBKeyboardConfiguration()]
  }

  func pointingDevices() -> [VZPointingDeviceConfiguration] {
    [VZUSBScreenCoordinatePointingDeviceConfiguration()]
  }

  func pointingDevicesSimplified() -> [VZPointingDeviceConfiguration] {
    // Linux doesn't support trackpad, so just return the regular pointing devices
    return pointingDevices()
  }

  func pointingDevicesSuspendable() -> [VZPointingDeviceConfiguration] {
    // VZUSBScreenCoordinatePointingDeviceConfiguration passes save/restore
    // validation, but causes restoring a Linux VM to fail with "invalid argument".
    []
  }

  func keyboardsSuspendable() -> [VZKeyboardConfiguration] {
    keyboards()
  }
}

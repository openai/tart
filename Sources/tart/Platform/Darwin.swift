import Virtualization

struct UnsupportedHostOSError: Error, CustomStringConvertible {
  var description: String {
    "error: host macOS version is outdated to run this virtual machine"
  }
}

#if arch(arm64)

  struct Darwin: PlatformSuspendable {
    var ecid: VZMacMachineIdentifier
    var hardwareModel: VZMacHardwareModel

    init(ecid: VZMacMachineIdentifier, hardwareModel: VZMacHardwareModel) {
      self.ecid = ecid
      self.hardwareModel = hardwareModel
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)

      let encodedECID = try container.decode(String.self, forKey: .ecid)
      guard let data = Data.init(base64Encoded: encodedECID) else {
        throw DecodingError.dataCorruptedError(forKey: .ecid,
                                               in: container,
                                               debugDescription: "failed to initialize Data using the provided value")
      }
      guard let ecid = VZMacMachineIdentifier.init(dataRepresentation: data) else {
        throw DecodingError.dataCorruptedError(forKey: .ecid,
                                               in: container,
                                               debugDescription: "failed to initialize VZMacMachineIdentifier using the provided value")
      }
      self.ecid = ecid

      let encodedHardwareModel = try container.decode(String.self, forKey: .hardwareModel)
      guard let data = Data.init(base64Encoded: encodedHardwareModel) else {
        throw DecodingError.dataCorruptedError(forKey: .hardwareModel, in: container, debugDescription: "")
      }
      guard let hardwareModel = VZMacHardwareModel.init(dataRepresentation: data) else {
        throw UnsupportedHostOSError()
      }
      self.hardwareModel = hardwareModel
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)

      try container.encode(ecid.dataRepresentation.base64EncodedString(), forKey: .ecid)
      try container.encode(hardwareModel.dataRepresentation.base64EncodedString(), forKey: .hardwareModel)
    }

    func os() -> OS {
      .darwin
    }

    func bootLoader(nvramURL: URL) throws -> VZBootLoader {
      VZMacOSBootLoader()
    }

    func platform(nvramURL: URL, needsNestedVirtualization: Bool) throws -> VZPlatformConfiguration {
      if needsNestedVirtualization {
        throw RuntimeError.VMConfigurationError("macOS virtual machines do not support nested virtualization")
      }

      let result = VZMacPlatformConfiguration()

      result.machineIdentifier = ecid
      result.auxiliaryStorage = VZMacAuxiliaryStorage(url: nvramURL)

      if !hardwareModel.isSupported {
        // At the moment support of M1 chip is not yet dropped in any macOS version
        // This mean that host software is not supporting this hardware model and should be updated
        throw UnsupportedHostOSError()
      }

      result.hardwareModel = hardwareModel

      return result
    }

    func graphicsDevice(vmConfig: VMConfig) -> VZGraphicsDeviceConfiguration {
      let result = VZMacGraphicsDeviceConfiguration()

      if (vmConfig.display.unit ?? .point) == .point, let hostMainScreen = NSScreen.main {
        let vmScreenSize = NSSize(width: vmConfig.display.width, height: vmConfig.display.height)
        result.displays = [
          VZMacGraphicsDisplayConfiguration(for: hostMainScreen, sizeInPoints: vmScreenSize)
        ]

        return result
      }

      result.displays = [
        VZMacGraphicsDisplayConfiguration(
          widthInPixels: vmConfig.display.width,
          heightInPixels: vmConfig.display.height,
          // Defaults to 72 — a reasonable guess according to Apple's
          // documentation[1] — unless a --display "@PPI" hint asks for a
          // Retina-class density (which yields a HiDPI guest mode).
          // [1]: https://developer.apple.com/documentation/coregraphics/1456599-cgdisplayscreensize
          pixelsPerInch: vmConfig.display.effectivePixelsPerInch
        )
      ]

      return result
    }

    func keyboards() -> [VZKeyboardConfiguration] {
      if #available(macOS 14, *) {
        // Mac keyboard is only supported by guests starting with macOS Ventura
        return [VZUSBKeyboardConfiguration(), VZMacKeyboardConfiguration()]
      } else {
        return [VZUSBKeyboardConfiguration()]
      }
    }

    func keyboardsSuspendable() -> [VZKeyboardConfiguration] {
      if #available(macOS 14, *) {
        return [VZMacKeyboardConfiguration()]
      } else {
        // fallback to the regular configuration
        return keyboards()
      }
    }

    func pointingDevices() -> [VZPointingDeviceConfiguration] {
      // Trackpad is only supported by guests starting with macOS Ventura
      [VZUSBScreenCoordinatePointingDeviceConfiguration(), VZMacTrackpadConfiguration()]
    }

    func pointingDevicesSimplified() -> [VZPointingDeviceConfiguration] {
      // Only include the USB pointing device, not the trackpad
      return [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    func pointingDevicesSuspendable() -> [VZPointingDeviceConfiguration] {
      if #available(macOS 14, *) {
        return [VZMacTrackpadConfiguration()]
      } else {
        // fallback to the regular configuration
        return pointingDevices()
      }
    }
  }

#endif

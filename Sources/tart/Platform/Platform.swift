import Virtualization

protocol Platform: Codable {
  func os() -> OS
  func bootLoader(nvramURL: URL) throws -> VZBootLoader
  func platform(nvramURL: URL, needsNestedVirtualization: Bool) throws -> VZPlatformConfiguration
  func graphicsDevice(vmConfig: VMConfig) -> VZGraphicsDeviceConfiguration
  func keyboards(noUSB: Bool) -> [VZKeyboardConfiguration]
  func pointingDevices(noUSB: Bool) -> [VZPointingDeviceConfiguration]
  func pointingDevicesSimplified(noUSB: Bool) -> [VZPointingDeviceConfiguration]
}

protocol PlatformSuspendable: Platform {
  func pointingDevicesSuspendable(noUSB: Bool) -> [VZPointingDeviceConfiguration]
  func keyboardsSuspendable(noUSB: Bool) -> [VZKeyboardConfiguration]
}

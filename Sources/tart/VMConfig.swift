import Virtualization

class LessThanMinimalResourcesError: NSObject, LocalizedError {
  var userExplanation: String

  init(_ userExplanation: String) {
    self.userExplanation = userExplanation
  }

  override var description: String {
    get {
      "LessThanMinimalResourcesError: \(userExplanation)"
    }
  }
}

enum CodingKeys: String, CodingKey {
  case version
  case os
  case arch
  case cpuCountMin
  case cpuCount
  case memorySizeMin
  case memorySize
  case macAddress
  case display
  case displayRefit
  case diskFormat
  case memoryBalloon

  // macOS-specific keys
  case ecid
  case hardwareModel
}

struct VMDisplayConfig: Codable, Equatable {
  enum Unit: String, Codable {
    case point = "pt"
    case pixel = "px"
  }

  var width: Int = 1024
  var height: Int = 768
  var unit: Unit?
}

extension VMDisplayConfig: CustomStringConvertible {
  var description: String {
    if let unit {
      "\(width)x\(height)\(unit.rawValue)"
    } else {
      "\(width)x\(height)"
    }
  }
}

struct VMConfig: Codable {
  var version: Int = 1
  var os: OS
  var arch: Architecture
  var platform: Platform
  var cpuCountMin: Int
  private(set) var cpuCount: Int
  var memorySizeMin: UInt64
  private(set) var memorySize: UInt64
  var macAddress: VZMACAddress
  var display: VMDisplayConfig = VMDisplayConfig()
  var displayRefit: Bool?
  var diskFormat: DiskImageFormat = .raw
  var memoryBalloon: Bool = false

  init(
    platform: Platform,
    cpuCountMin: Int,
    memorySizeMin: UInt64,
    macAddress: VZMACAddress = VZMACAddress.randomLocallyAdministered(),
    diskFormat: DiskImageFormat = .raw
  ) {
    self.os = platform.os()
    self.arch = CurrentArchitecture()
    self.platform = platform
    self.macAddress = macAddress
    self.cpuCountMin = cpuCountMin
    self.memorySizeMin = memorySizeMin
    self.diskFormat = diskFormat
    cpuCount = cpuCountMin
    memorySize = memorySizeMin
  }

  init(fromJSON: Data) throws {
    self = try Config.jsonDecoder().decode(Self.self, from: fromJSON)
  }

  init(fromURL: URL) throws {
    self = try Self(fromJSON: try Data(contentsOf: fromURL))
  }

  func toJSON() throws -> Data {
    try Config.jsonEncoder().encode(self)
  }

  func save(toURL: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    try encoder.encode(self).write(to: toURL)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    version = try container.decode(Int.self, forKey: .version)
    os = try container.decodeIfPresent(OS.self, forKey: .os) ?? .darwin
    arch = try container.decodeIfPresent(Architecture.self, forKey: .arch) ?? .arm64
    switch os {
    case .darwin:
      #if arch(arm64)
        platform = try Darwin(from: decoder)
      #else
        throw DecodingError.dataCorruptedError(
          forKey: .os,
          in: container,
          debugDescription: "Darwin VMs are only supported on Apple Silicon hosts")
      #endif
    case .linux:
      platform = try Linux(from: decoder)
    }
    cpuCountMin = try container.decode(Int.self, forKey: .cpuCountMin)
    cpuCount = try container.decode(Int.self, forKey: .cpuCount)
    memorySizeMin = try container.decode(UInt64.self, forKey: .memorySizeMin)
    memorySize = try container.decode(UInt64.self, forKey: .memorySize)

    let encodedMacAddress = try container.decode(String.self, forKey: .macAddress)
    guard let macAddress = VZMACAddress.init(string: encodedMacAddress) else {
      throw DecodingError.dataCorruptedError(
        forKey: .hardwareModel,
        in: container,
        debugDescription: "failed to initialize VZMacAddress using the provided value")
    }
    self.macAddress = macAddress

    display = try container.decodeIfPresent(VMDisplayConfig.self, forKey: .display) ?? VMDisplayConfig()
    displayRefit = try container.decodeIfPresent(Bool.self, forKey: .displayRefit)
    let diskFormatString = try container.decodeIfPresent(String.self, forKey: .diskFormat) ?? "raw"
    diskFormat = DiskImageFormat(rawValue: diskFormatString) ?? .raw
    memoryBalloon = try container.decodeIfPresent(Bool.self, forKey: .memoryBalloon) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    try container.encode(version, forKey: .version)
    try container.encode(os, forKey: .os)
    try container.encode(arch, forKey: .arch)
    try platform.encode(to: encoder)
    try container.encode(cpuCountMin, forKey: .cpuCountMin)
    try container.encode(cpuCount, forKey: .cpuCount)
    try container.encode(memorySizeMin, forKey: .memorySizeMin)
    try container.encode(memorySize, forKey: .memorySize)
    try container.encode(macAddress.string, forKey: .macAddress)
    try container.encode(display, forKey: .display)
    if let displayRefit = displayRefit {
      try container.encode(displayRefit, forKey: .displayRefit)
    }
    try container.encode(diskFormat.rawValue, forKey: .diskFormat)
    // Only write the key when the balloon is enabled, so that configurations
    // of VMs that don't use this feature remain byte-identical to those
    // produced by older Tart versions
    if memoryBalloon {
      try container.encode(memoryBalloon, forKey: .memoryBalloon)
    }
  }

  mutating func setCPU(cpuCount: Int) throws {
    if os == .darwin && cpuCount < cpuCountMin {
      throw LessThanMinimalResourcesError("VM should have \(cpuCountMin) CPU cores"
        + " at minimum (requested \(cpuCount))")
    }

    if cpuCount < VZVirtualMachineConfiguration.minimumAllowedCPUCount {
      throw LessThanMinimalResourcesError("VM should have \(VZVirtualMachineConfiguration.minimumAllowedCPUCount) CPU cores"
        + " at minimum (requested \(cpuCount))")
    }

    self.cpuCount = cpuCount
  }

  mutating func setMemory(memorySize: UInt64) throws {
    if os == .darwin && memorySize < memorySizeMin {
      throw LessThanMinimalResourcesError("VM should have \(memorySizeMin) bytes"
        + " of memory at minimum (requested \(memorySize))")
    }

    if memorySize < VZVirtualMachineConfiguration.minimumAllowedMemorySize {
      throw LessThanMinimalResourcesError("VM should have \(VZVirtualMachineConfiguration.minimumAllowedMemorySize) bytes"
        + " of memory at minimum (requested \(memorySize))")
    }

    self.memorySize = memorySize
  }
}

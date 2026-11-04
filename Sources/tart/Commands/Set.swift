import ArgumentParser
import Foundation
import Virtualization

struct Set: AsyncParsableCommand {
  static var configuration = CommandConfiguration(commandName: "set", abstract: "Modify VM's configuration")

  @Argument(help: "VM name", completion: .custom(completeLocalMachines))
  var name: String

  @Option(help: "Number of VM CPUs")
  var cpu: UInt16?

  @Option(help: "VM memory size in megabytes")
  var memory: UInt64?

  @Option(help: "VM display resolution in a format of WIDTHxHEIGHT[pt|px]. For example, 1200x800, 1200x800pt or 1920x1080px. Units are treated as hints and default to \"pt\" (points) for macOS VMs and \"px\" (pixels) for Linux VMs when not specified.")
  var display: VMDisplayConfig?

  @Flag(inversion: .prefixedNo, help: ArgumentHelp("Whether to automatically reconfigure the VM's display to fit the window"))
  var displayRefit: Bool? = nil

  @Option(help: ArgumentHelp("MAC address to use."), transform: { value in
    guard let address = VZMACAddress(string: value) else {
      throw ValidationError("'\(value)' is not a valid MAC address")
    }

    guard address.isUnicastAddress else {
      throw ValidationError("'\(value)' is not a unicast MAC address")
    }

    return address
  })
  var mac: VZMACAddress?

  @Flag(help: ArgumentHelp("Generate a new random MAC address for the VM."))
  var randomMAC: Bool = false

  #if arch(arm64)
    @Flag(help: ArgumentHelp("Generate a new random serial number for the macOS VM."))
  #endif
  var randomSerial: Bool = false

  @Option(help: ArgumentHelp("Replace the VM's disk contents with the disk contents at path.", valueName: "path"))
  var disk: String?

  @Option(help: ArgumentHelp("Resize the VMs disk to the specified size in GB (note that the disk size can only be increased to avoid losing data)",
                             discussion: """
                             See https://tart.run/faq/#disk-resizing for more details.
                             """))
  var diskSize: UInt16?

  func run() async throws {
    // Serialize configuration updates with "tart clone" and "tart run"
    let storageLock = try FileLock(lockURL: Config().tartHomeDir)
    try storageLock.lock()

    let localStorage = try VMStorageLocal()
    let vmDir = try localStorage.open(name)

    // Replacing disk.img would leave a stacked VM with both disk.img and
    // overlay.asif, which is not a supported local layout. Reject before
    // saving any other requested configuration changes.
    if disk != nil, vmDir.isStackedVM {
      throw ValidationError("--disk is not supported for VMs with a stacked disk")
    }

    if randomMAC && mac != nil {
      throw ValidationError("--random-mac and --mac are mutually exclusive")
    }

    var vmConfig = try VMConfig(fromURL: vmDir.configURL)

    if let cpu = cpu {
      try vmConfig.setCPU(cpuCount: Int(cpu))
    }

    if let memory = memory {
      try vmConfig.setMemory(memorySize: memory * 1024 * 1024)
    }

    if let display = display {
      if (display.width > 0) {
        vmConfig.display.width = display.width
      }
      if (display.height > 0) {
        vmConfig.display.height = display.height
      }
      vmConfig.display.unit = display.unit
    }

    if let displayRefit = displayRefit {
      vmConfig.displayRefit = displayRefit
    }

    if let mac, mac.string != vmConfig.macAddress.string {
      // A running or suspended VM must retain its MAC address
      if try vmDir.state() != .Stopped {
        throw ValidationError("MAC address cannot be changed while the VM is running or suspended")
      }

      if try localStorage.hasVMsWithMACAddress(macAddress: mac.string) {
        throw ValidationError("MAC address '\(mac.string)' is already used by another VM")
      }

      vmConfig.macAddress = mac
    }

    if randomMAC {
      // A running or suspended VM must retain its MAC address
      if try vmDir.state() != .Stopped {
        throw ValidationError("MAC address cannot be changed while the VM is running or suspended")
      }

      // Retry collisions, including the VM's current address
      repeat {
        vmConfig.macAddress = VZMACAddress.randomLocallyAdministered()
      } while try localStorage.hasVMsWithMACAddress(macAddress: vmConfig.macAddress.string)
    }

    #if arch(arm64)
      if randomSerial, let oldPlatform = vmConfig.platform as? Darwin {
        vmConfig.platform = Darwin(ecid: VZMacMachineIdentifier(), hardwareModel: oldPlatform.hardwareModel)
      }
    #endif

    try vmConfig.save(toURL: vmDir.configURL)
    try storageLock.unlock()

    if let disk = disk {
      let temporaryDiskURL = try Config().tartTmpDir.appendingPathComponent("set-disk-\(UUID().uuidString)")

      try FileManager.default.copyItem(atPath: disk, toPath: temporaryDiskURL.path(percentEncoded: false))

      _ = try FileManager.default.replaceItemAt(vmDir.diskURL, withItemAt: temporaryDiskURL)
    }

    if diskSize != nil {
      try vmDir.resizeDisk(diskSize!)
    }
  }
}

extension VMDisplayConfig: ExpressibleByArgument {
  public init(argument: String) {
    var argument = argument
    var unit: Unit? = nil

    if argument.hasSuffix(Unit.pixel.rawValue) {
      argument = String(argument.dropLast(Unit.pixel.rawValue.count))
      unit = Unit.pixel
    } else if argument.hasSuffix(Unit.point.rawValue) {
      argument = String(argument.dropLast(Unit.point.rawValue.count))
      unit = Unit.point
    }

    let parts = argument.components(separatedBy: "x").map {
      Int($0) ?? 0
    }
    self = VMDisplayConfig(
      width: parts[safe: 0] ?? 0,
      height: parts[safe: 1] ?? 0,
      unit: unit,
    )
  }
}

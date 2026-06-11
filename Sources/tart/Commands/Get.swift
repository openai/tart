import ArgumentParser
import Foundation

struct GetVMInfo: Encodable {
  let OS: OS
  let CPU: Int
  let Memory: UInt64
  let Disk: Int
  let DiskFormat: String
  let Size: String
  let Display: String
  let Running: Bool
  let State: String

  private let diskBytes: Int
  private let sizeBytes: Int

  enum CodingKeys: String, CodingKey {
    case OS
    case CPU
    case Memory
    case Disk
    case DiskFormat
    case Size
    case Display
    case Running
    case State
  }

  init(
    OS: OS,
    CPU: Int,
    Memory: UInt64,
    diskBytes: Int,
    DiskFormat: String,
    sizeBytes: Int,
    Display: String,
    Running: Bool,
    State: String
  ) {
    self.OS = OS
    self.CPU = CPU
    self.Memory = Memory
    self.Disk = diskBytes / 1000 / 1000 / 1000
    self.DiskFormat = DiskFormat
    self.Size = String(format: "%.3f", Float(sizeBytes) / 1000 / 1000 / 1000)
    self.Display = Display
    self.Running = Running
    self.State = State
    self.diskBytes = diskBytes
    self.sizeBytes = sizeBytes
  }

  var textInfo: GetVMTextInfo {
    GetVMTextInfo(
      OS: OS,
      CPU: CPU,
      Memory: Memory,
      Disk: ByteCountFormatter.string(fromByteCount: Int64(diskBytes), countStyle: .file),
      DiskFormat: DiskFormat,
      Size: ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file),
      Display: Display,
      Running: Running,
      State: State
    )
  }
}

struct GetVMTextInfo: Encodable {
  let OS: OS
  let CPU: Int
  let Memory: UInt64
  let Disk: String
  let DiskFormat: String
  let Size: String
  let Display: String
  let Running: Bool
  let State: String
}

struct Get: AsyncParsableCommand {
  static var configuration = CommandConfiguration(commandName: "get", abstract: "Get a VM's configuration")

  @Argument(help: "VM name.", completion: .custom(completeLocalMachines))
  var name: String

  @Option(help: "Output format: text or json")
  var format: Format = .text

  func run() async throws {
    let vmDir = try VMStorageLocal().open(name)
    let vmConfig = try VMConfig(fromURL: vmDir.configURL)
    let memorySizeInMb = vmConfig.memorySize / 1024 / 1024

    let info = GetVMInfo(
      OS: vmConfig.os,
      CPU: vmConfig.cpuCount,
      Memory: memorySizeInMb,
      diskBytes: try vmDir.sizeBytes(),
      DiskFormat: vmConfig.diskFormat.rawValue,
      sizeBytes: try vmDir.allocatedSizeBytes(),
      Display: vmConfig.display.description,
      Running: try vmDir.running(),
      State: try vmDir.state().rawValue
    )

    switch format {
    case .text:
      print(format.renderSingle(info.textInfo))
    case .json:
      print(format.renderSingle(info))
    }
  }
}

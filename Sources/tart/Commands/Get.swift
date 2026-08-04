import ArgumentParser
import Foundation

fileprivate struct VMInfo: Encodable {
  let OS: OS
  let CPU: Int
  let Memory: UInt64
  let Disk: HumanReadableByteCount
  let DiskFormat: String
  let Size: HumanReadableByteCount
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

    let info = VMInfo(
      OS: vmConfig.os,
      CPU: vmConfig.cpuCount,
      Memory: memorySizeInMb,
      Disk: HumanReadableByteCount(try vmDir.sizeBytes()) { $0 / 1000 / 1000 / 1000 },
      DiskFormat: vmConfig.diskFormat.rawValue,
      Size: HumanReadableByteCount(try vmDir.allocatedSizeBytes()) {
        String(format: "%.3f", Float($0) / 1000 / 1000 / 1000)
      },
      Display: vmConfig.display.description,
      Running: try vmDir.running(),
      State: try vmDir.state().rawValue
    )

    print(format.renderSingle(info))
  }
}

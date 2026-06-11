import ArgumentParser
import Dispatch
import Foundation
import SwiftUI

struct ListVMInfo: Encodable {
  let Source: String
  let Name: String
  let Disk: Int
  let Size: Int
  let Accessed: String
  let Running: Bool
  let State: String

  private let diskBytes: Int
  private let sizeBytes: Int

  enum CodingKeys: String, CodingKey {
    case Source
    case Name
    case Disk
    case Size
    case Accessed
    case Running
    case State
  }

  init(Source: String, Name: String, diskBytes: Int, sizeBytes: Int, Accessed: String, Running: Bool, State: String) {
    self.Source = Source
    self.Name = Name
    self.Disk = diskBytes / 1000 / 1000 / 1000
    self.Size = sizeBytes / 1000 / 1000 / 1000
    self.Accessed = Accessed
    self.Running = Running
    self.State = State
    self.diskBytes = diskBytes
    self.sizeBytes = sizeBytes
  }

  var textInfo: ListVMTextInfo {
    ListVMTextInfo(
      Source: Source,
      Name: Name,
      Disk: ByteCountFormatter.string(fromByteCount: Int64(diskBytes), countStyle: .file),
      Size: ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file),
      Accessed: Accessed,
      Running: Running,
      State: State
    )
  }
}

struct ListVMTextInfo: Encodable {
  let Source: String
  let Name: String
  let Disk: String
  let Size: String
  let Accessed: String
  let Running: Bool
  let State: String
}

struct List: AsyncParsableCommand {
  static var configuration = CommandConfiguration(abstract: "List created VMs")

  @Option(help: ArgumentHelp("Only display VMs from the specified source (e.g. --source local, --source oci)."))
  var source: String?

  @Option(help: "Output format: text or json", completion: .list(["text", "json"]))
  var format: Format = .text

  @Flag(name: [.short, .long], help: ArgumentHelp("Only display VM names."))
  var quiet: Bool = false

  func validate() throws {
    guard let source = source else {
      return
    }

    if !["local", "oci"].contains(source) {
      throw ValidationError("'\(source)' is not a valid <source>")
    }
  }

  func run() async throws {
    var infos: [ListVMInfo] = []

    if source == nil || source == "local" {
      infos += sortedInfos(try VMStorageLocal().list().map { (name, vmDir) in
        try ListVMInfo(
          Source: "local",
          Name: name,
          diskBytes: vmDir.sizeBytes(),
          sizeBytes: vmDir.allocatedSizeBytes(),
          Accessed: formatAccessDate(try vmDir.accessDate()),
          Running: vmDir.running(),
          State: vmDir.state().rawValue
        )
      })
    }

    if source == nil || source == "oci" {
      infos += sortedInfos(try VMStorageOCI().list().map { (name, vmDir, _) in
        try ListVMInfo(
          Source: "OCI",
          Name: name,
          diskBytes: vmDir.sizeBytes(),
          sizeBytes: vmDir.allocatedSizeBytes(),
          Accessed: formatAccessDate(try vmDir.accessDate()),
          Running: vmDir.running(),
          State: vmDir.state().rawValue
        )
      })
    }

    if (quiet) {
      for info in infos {
        print(info.Name)
      }
    } else {
      switch format {
      case .text:
        print(format.renderList(infos.map { $0.textInfo }))
      case .json:
        print(format.renderList(infos))
      }
    }
  }

  private func sortedInfos(_ infos: [ListVMInfo]) -> [ListVMInfo] {
    infos.sorted(by: { left, right in left.Name < right.Name })
  }

  private func formatAccessDate(_ accessDate: Date) -> String {
    switch format {
    case .text:
      let formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .full
      return formatter.localizedString(for: accessDate, relativeTo: Date())
    case .json:
      let formatter = ISO8601DateFormatter()
      return formatter.string(from: accessDate)
    }
  }
}
